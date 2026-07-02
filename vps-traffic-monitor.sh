#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

CONFIG_FILE="${VPS_TRAFFIC_CONFIG:-}"
MODE=""
DRY_RUN=0

PUSH_CHANNEL="${PUSH_CHANNEL:-}"
VPS_NAME="${VPS_NAME:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
BARK_URL="${BARK_URL:-}"
TRAFFIC_LIMIT_GB="${TRAFFIC_LIMIT_GB:-1024}"
ALERT_PERCENT="${ALERT_PERCENT:-80}"
IFACE="${IFACE:-auto}"
STATE_DIR="${STATE_DIR:-/var/lib/vps-traffic-monitor}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOCK_DIR=""

usage() {
  cat <<'EOF'
Usage:
  vps-traffic-monitor.sh --config /etc/vps-traffic-monitor.env --check
  vps-traffic-monitor.sh --config /etc/vps-traffic-monitor.env --daily
  vps-traffic-monitor.sh --config /etc/vps-traffic-monitor.env --weekly
  vps-traffic-monitor.sh --config /etc/vps-traffic-monitor.env --monthly
  vps-traffic-monitor.sh --config /etc/vps-traffic-monitor.env --test-push

Options:
  --config PATH   Read configuration from PATH.
  --dry-run       Print notification content instead of sending it.
  --check         Update counters and send quota alerts when needed.
  --daily         Send a daily traffic report.
  --weekly        Send a weekly traffic report.
  --monthly       Send a monthly traffic report.
  --test-push     Test the configured push channel without changing state.
  --help          Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_optional_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

load_config() {
  local file="$1"
  [[ -n "$file" ]] || return 0
  [[ -r "$file" ]] || die "config file is not readable: $file"

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    [[ "$line" == *=* ]] || die "invalid config line: $line"
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    value="$(strip_optional_quotes "$value")"

    case "$key" in
      PUSH_CHANNEL) PUSH_CHANNEL="$value" ;;
      VPS_NAME) VPS_NAME="$value" ;;
      TG_BOT_TOKEN) TG_BOT_TOKEN="$value" ;;
      TG_CHAT_ID) TG_CHAT_ID="$value" ;;
      BARK_URL) BARK_URL="$value" ;;
      TRAFFIC_LIMIT_GB) TRAFFIC_LIMIT_GB="$value" ;;
      ALERT_PERCENT) ALERT_PERCENT="$value" ;;
      IFACE) IFACE="$value" ;;
      STATE_DIR) STATE_DIR="$value" ;;
      TIMEZONE) TIMEZONE="$value" ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$file"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --check|--daily|--weekly|--monthly|--test-push)
        [[ -z "$MODE" ]] || die "only one mode can be selected"
        MODE="${1#--}"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --version)
        printf '%s\n' "$VERSION"
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$MODE" ]] || die "select one mode: --check, --daily, --weekly, --monthly, or --test-push"
}

validate_config() {
  PUSH_CHANNEL="$(printf '%s' "$PUSH_CHANNEL" | tr '[:upper:]' '[:lower:]')"
  case "$PUSH_CHANNEL" in
    telegram)
      [[ -n "$TG_BOT_TOKEN" ]] || die "TG_BOT_TOKEN is required for telegram"
      [[ -n "$TG_CHAT_ID" ]] || die "TG_CHAT_ID is required for telegram"
      ;;
    bark)
      [[ -n "$BARK_URL" ]] || die "BARK_URL is required for bark"
      ;;
    *)
      die "PUSH_CHANNEL must be telegram or bark"
      ;;
  esac

  is_uint "$TRAFFIC_LIMIT_GB" || die "TRAFFIC_LIMIT_GB must be an integer"
  is_uint "$ALERT_PERCENT" || die "ALERT_PERCENT must be an integer"
  (( TRAFFIC_LIMIT_GB > 0 )) || die "TRAFFIC_LIMIT_GB must be greater than 0"
  (( ALERT_PERCENT > 0 && ALERT_PERCENT <= 100 )) || die "ALERT_PERCENT must be between 1 and 100"

  [[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "IFACE contains unsafe characters"
  [[ "$STATE_DIR" = /* || "$STATE_DIR" = ~* ]] || die "STATE_DIR must be an absolute path"
  [[ "$VPS_NAME" != *$'\n'* && "$TG_BOT_TOKEN" != *$'\n'* && "$TG_CHAT_ID" != *$'\n'* && "$BARK_URL" != *$'\n'* ]] || die "settings must not contain newlines"
  [[ "$VPS_NAME" != *\"* ]] || die "VPS_NAME must not contain double quotes"
  [[ "$BARK_URL" != *\"* ]] || die "BARK_URL must not contain double quotes"
  [[ "$TG_BOT_TOKEN" != *\"* ]] || die "TG_BOT_TOKEN must not contain double quotes"
}

detect_iface() {
  if [[ "$IFACE" != "auto" ]]; then
    [[ -d "/sys/class/net/$IFACE" ]] || die "network interface not found: $IFACE"
    printf '%s\n' "$IFACE"
    return 0
  fi

  local via_ip iface
  if command -v ip >/dev/null 2>&1; then
    via_ip="$(ip route get 1.1.1.1 2>/dev/null || true)"
    iface="$(printf '%s\n' "$via_ip" | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
    if [[ -n "$iface" && -d "/sys/class/net/$iface" && "$iface" != "lo" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  fi

  awk -F: '
    NR > 2 {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 !~ /^(lo|docker[0-9]*|br-|veth|virbr|tun|tap|wg|tailscale|zt|cni|flannel)/) {
        print $1
        exit
      }
    }
  ' /proc/net/dev
}

read_counter() {
  local iface="$1"
  local name="$2"
  local path="/sys/class/net/$iface/statistics/${name}_bytes"
  [[ -r "$path" ]] || die "cannot read $path"
  local value
  value="$(cat "$path")"
  is_uint "$value" || die "invalid counter value in $path"
  printf '%s\n' "$value"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

acquire_lock() {
  LOCK_DIR="$STATE_DIR/.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another vps-traffic-monitor process is running"
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

period_day() {
  TZ="$TIMEZONE" date +%F
}

period_week() {
  TZ="$TIMEZONE" date +%G-W%V
}

period_month() {
  TZ="$TIMEZONE" date +%Y-%m
}

now_text() {
  TZ="$TIMEZONE" date '+%F %T %Z'
}

state_file_for_iface() {
  local iface="$1"
  printf '%s/%s.state\n' "$STATE_DIR" "$iface"
}

load_state() {
  local file="$1"
  LAST_RX=0
  LAST_TX=0
  TOTAL_RX=0
  TOTAL_TX=0
  DAY_KEY="$(period_day)"
  DAY_RX=0
  DAY_TX=0
  WEEK_KEY="$(period_week)"
  WEEK_RX=0
  WEEK_TX=0
  MONTH_KEY="$(period_month)"
  MONTH_RX=0
  MONTH_TX=0
  PREV_DAY_KEY=""
  PREV_DAY_RX=0
  PREV_DAY_TX=0
  PREV_WEEK_KEY=""
  PREV_WEEK_RX=0
  PREV_WEEK_TX=0
  PREV_MONTH_KEY=""
  PREV_MONTH_RX=0
  PREV_MONTH_TX=0
  ALERT_80_SENT=""
  ALERT_100_SENT=""

  [[ -f "$file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "${line:0:1}" == "#" || "$line" != *=* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      LAST_RX|LAST_TX|TOTAL_RX|TOTAL_TX|DAY_RX|DAY_TX|WEEK_RX|WEEK_TX|MONTH_RX|MONTH_TX|PREV_DAY_RX|PREV_DAY_TX|PREV_WEEK_RX|PREV_WEEK_TX|PREV_MONTH_RX|PREV_MONTH_TX)
        is_uint "$value" || value=0
        printf -v "$key" '%s' "$value"
        ;;
      DAY_KEY|WEEK_KEY|MONTH_KEY|PREV_DAY_KEY|PREV_WEEK_KEY|PREV_MONTH_KEY|ALERT_80_SENT|ALERT_100_SENT)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
}

save_state() {
  local file="$1"
  local tmp="${file}.tmp.$$"
  umask 077
  cat > "$tmp" <<EOF
LAST_RX=$LAST_RX
LAST_TX=$LAST_TX
TOTAL_RX=$TOTAL_RX
TOTAL_TX=$TOTAL_TX
DAY_KEY=$DAY_KEY
DAY_RX=$DAY_RX
DAY_TX=$DAY_TX
WEEK_KEY=$WEEK_KEY
WEEK_RX=$WEEK_RX
WEEK_TX=$WEEK_TX
MONTH_KEY=$MONTH_KEY
MONTH_RX=$MONTH_RX
MONTH_TX=$MONTH_TX
PREV_DAY_KEY=$PREV_DAY_KEY
PREV_DAY_RX=$PREV_DAY_RX
PREV_DAY_TX=$PREV_DAY_TX
PREV_WEEK_KEY=$PREV_WEEK_KEY
PREV_WEEK_RX=$PREV_WEEK_RX
PREV_WEEK_TX=$PREV_WEEK_TX
PREV_MONTH_KEY=$PREV_MONTH_KEY
PREV_MONTH_RX=$PREV_MONTH_RX
PREV_MONTH_TX=$PREV_MONTH_TX
ALERT_80_SENT=$ALERT_80_SENT
ALERT_100_SENT=$ALERT_100_SENT
EOF
  mv "$tmp" "$file"
}

reset_periods_if_needed() {
  local today week month
  today="$(period_day)"
  week="$(period_week)"
  month="$(period_month)"

  if [[ "$DAY_KEY" != "$today" ]]; then
    PREV_DAY_KEY="$DAY_KEY"
    PREV_DAY_RX="$DAY_RX"
    PREV_DAY_TX="$DAY_TX"
    DAY_KEY="$today"
    DAY_RX=0
    DAY_TX=0
  fi
  if [[ "$WEEK_KEY" != "$week" ]]; then
    PREV_WEEK_KEY="$WEEK_KEY"
    PREV_WEEK_RX="$WEEK_RX"
    PREV_WEEK_TX="$WEEK_TX"
    WEEK_KEY="$week"
    WEEK_RX=0
    WEEK_TX=0
  fi
  if [[ "$MONTH_KEY" != "$month" ]]; then
    PREV_MONTH_KEY="$MONTH_KEY"
    PREV_MONTH_RX="$MONTH_RX"
    PREV_MONTH_TX="$MONTH_TX"
    MONTH_KEY="$month"
    MONTH_RX=0
    MONTH_TX=0
    ALERT_80_SENT=""
    ALERT_100_SENT=""
  fi
}

update_counters() {
  local iface="$1"
  local current_rx current_tx delta_rx delta_tx
  current_rx="$(read_counter "$iface" rx)"
  current_tx="$(read_counter "$iface" tx)"

  if (( LAST_RX == 0 && LAST_TX == 0 )); then
    LAST_RX="$current_rx"
    LAST_TX="$current_tx"
    return 0
  fi

  if (( current_rx < LAST_RX )); then
    delta_rx=0
  else
    delta_rx=$(( current_rx - LAST_RX ))
  fi
  if (( current_tx < LAST_TX )); then
    delta_tx=0
  else
    delta_tx=$(( current_tx - LAST_TX ))
  fi

  TOTAL_RX=$(( TOTAL_RX + delta_rx ))
  TOTAL_TX=$(( TOTAL_TX + delta_tx ))
  DAY_RX=$(( DAY_RX + delta_rx ))
  DAY_TX=$(( DAY_TX + delta_tx ))
  WEEK_RX=$(( WEEK_RX + delta_rx ))
  WEEK_TX=$(( WEEK_TX + delta_tx ))
  MONTH_RX=$(( MONTH_RX + delta_rx ))
  MONTH_TX=$(( MONTH_TX + delta_tx ))
  LAST_RX="$current_rx"
  LAST_TX="$current_tx"
}

bytes_to_gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.2f GiB", bytes / 1024 / 1024 / 1024 }'
}

percent_used() {
  local used_bytes="$1"
  local limit_gb="$2"
  awk -v used="$used_bytes" -v limit_gb="$limit_gb" 'BEGIN {
    limit = limit_gb * 1024 * 1024 * 1024
    if (limit <= 0) { printf "0.00"; exit }
    printf "%.2f", used * 100 / limit
  }'
}

percent_floor() {
  local used_bytes="$1"
  local limit_gb="$2"
  awk -v used="$used_bytes" -v limit_gb="$limit_gb" 'BEGIN {
    limit = limit_gb * 1024 * 1024 * 1024
    if (limit <= 0) { print 0; exit }
    printf "%d", used * 100 / limit
  }'
}

hostname_text() {
  if [[ -n "$VPS_NAME" ]]; then
    printf '%s\n' "$VPS_NAME"
    return 0
  fi
  hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || printf 'unknown-host'
}

report_body() {
  local title="$1"
  local iface="$2"
  local rx="$3"
  local tx="$4"
  local total=$(( rx + tx ))
  local month_total=$(( MONTH_RX + MONTH_TX ))
  local pct
  pct="$(percent_used "$month_total" "$TRAFFIC_LIMIT_GB")"
  cat <<EOF
$title
Host: $(hostname_text)
Time: $(now_text)
Interface: $iface

Period total: $(bytes_to_gib "$total")
  RX: $(bytes_to_gib "$rx")
  TX: $(bytes_to_gib "$tx")

Month total: $(bytes_to_gib "$month_total") / ${TRAFFIC_LIMIT_GB} GiB (${pct}%)
  Month RX: $(bytes_to_gib "$MONTH_RX")
  Month TX: $(bytes_to_gib "$MONTH_TX")
EOF
}

period_report_body() {
  local report_kind="$1"
  local iface="$2"
  local key rx tx

  case "$report_kind" in
    daily)
      if [[ -n "$PREV_DAY_KEY" ]]; then
        key="$PREV_DAY_KEY"
        rx="$PREV_DAY_RX"
        tx="$PREV_DAY_TX"
      else
        key="$DAY_KEY"
        rx="$DAY_RX"
        tx="$DAY_TX"
      fi
      report_body "Daily traffic report (${key})" "$iface" "$rx" "$tx"
      ;;
    weekly)
      if [[ -n "$PREV_WEEK_KEY" ]]; then
        key="$PREV_WEEK_KEY"
        rx="$PREV_WEEK_RX"
        tx="$PREV_WEEK_TX"
      else
        key="$WEEK_KEY"
        rx="$WEEK_RX"
        tx="$WEEK_TX"
      fi
      report_body "Weekly traffic report (${key})" "$iface" "$rx" "$tx"
      ;;
    monthly)
      if [[ -n "$PREV_MONTH_KEY" ]]; then
        key="$PREV_MONTH_KEY"
        rx="$PREV_MONTH_RX"
        tx="$PREV_MONTH_TX"
      else
        key="$MONTH_KEY"
        rx="$MONTH_RX"
        tx="$MONTH_TX"
      fi
      report_body "Monthly traffic report (${key})" "$iface" "$rx" "$tx"
      ;;
    *)
      die "unsupported report kind: $report_kind"
      ;;
  esac
}

send_notification() {
  local title="$1"
  local body="$2"

  if (( DRY_RUN )); then
    printf '[DRY-RUN] %s\n%s\n' "$title" "$body"
    return 0
  fi

  case "$PUSH_CHANNEL" in
    telegram)
      printf 'url = "%s"\n' "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" |
      curl -fsS --max-time 15 -K - \
        -X POST \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${title}
${body}" \
        --data-urlencode "disable_web_page_preview=true" \
        >/dev/null
      ;;
    bark)
      printf 'url = "%s"\n' "$BARK_URL" |
      curl -fsS --max-time 15 -K - \
        -X POST \
        --data-urlencode "title=${title}" \
        --data-urlencode "body=${body}" \
        >/dev/null
      ;;
    *)
      die "unsupported push channel: $PUSH_CHANNEL"
      ;;
  esac
}

maybe_send_alerts() {
  local iface="$1"
  local month_key="$MONTH_KEY"
  local month_total=$(( MONTH_RX + MONTH_TX ))
  local used_pct_int
  used_pct_int="$(percent_floor "$month_total" "$TRAFFIC_LIMIT_GB")"

  if (( used_pct_int >= ALERT_PERCENT )) && [[ "$ALERT_80_SENT" != "$month_key" ]]; then
    local title body
    title="VPS traffic alert: ${used_pct_int}% used"
    body="$(report_body "Monthly traffic reached ${ALERT_PERCENT}% threshold" "$iface" "$MONTH_RX" "$MONTH_TX")"
    send_notification "$title" "$body"
    ALERT_80_SENT="$month_key"
  fi

  if (( used_pct_int >= 100 )) && [[ "$ALERT_100_SENT" != "$month_key" ]]; then
    local title body
    title="VPS traffic exceeded monthly quota"
    body="$(report_body "Monthly traffic exceeded quota" "$iface" "$MONTH_RX" "$MONTH_TX")"
    send_notification "$title" "$body"
    ALERT_100_SENT="$month_key"
  fi
}

run_test_push() {
  send_notification "VPS traffic monitor test" "Push channel test succeeded at $(now_text). Host: $(hostname_text)"
}

main() {
  parse_args "$@"
  load_config "$CONFIG_FILE"
  validate_config
  export TZ="$TIMEZONE"

  if [[ "$MODE" == "test-push" ]]; then
    run_test_push
    return 0
  fi

  local iface state_file title body
  iface="$(detect_iface)"
  [[ -n "$iface" ]] || die "cannot detect a usable network interface"

  ensure_state_dir
  acquire_lock
  state_file="$(state_file_for_iface "$iface")"
  load_state "$state_file"
  reset_periods_if_needed
  update_counters "$iface"

  case "$MODE" in
    check)
      maybe_send_alerts "$iface"
      ;;
    daily)
      title="VPS daily traffic report"
      body="$(period_report_body daily "$iface")"
      send_notification "$title" "$body"
      ;;
    weekly)
      title="VPS weekly traffic report"
      body="$(period_report_body weekly "$iface")"
      send_notification "$title" "$body"
      ;;
    monthly)
      title="VPS monthly traffic report"
      body="$(period_report_body monthly "$iface")"
      send_notification "$title" "$body"
      ;;
    *)
      die "unsupported mode: $MODE"
      ;;
  esac

  save_state "$state_file"
}

main "$@"