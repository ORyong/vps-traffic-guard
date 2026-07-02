# vps-traffic-guard

Lightweight Bash traffic monitor for Linux VPS servers, including regular VPS
providers and Oracle Cloud instances.

It reads RX/TX counters from `/sys/class/net`, tracks monthly quota usage, and
sends Telegram Bot or Bark notifications for alerts plus daily, weekly, and
monthly reports.

## Features

- Bash only, no Python runtime required.
- Auto-detects the primary network interface.
- Supports Telegram Bot or Bark push notifications.
- Sends quota alerts at `ALERT_PERCENT`, default `80`.
- Sends another alert after monthly usage reaches `100%`.
- Supports daily, weekly, and monthly reports.
- Stores only traffic counters and alert state, never push secrets.

## Install

```bash
sudo install -m 755 vps-traffic-monitor.sh /usr/local/bin/vps-traffic-monitor
sudo install -m 600 vps-traffic-monitor.env.example /etc/vps-traffic-monitor.env
sudo editor /etc/vps-traffic-monitor.env
```

Test the push channel:

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --test-push
```

Test traffic detection without sending a push:

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --dry-run --check
```

## Cron

```cron
5 * * * * /usr/local/bin/vps-traffic-monitor --config /etc/vps-traffic-monitor.env --check
0 9 * * * /usr/local/bin/vps-traffic-monitor --config /etc/vps-traffic-monitor.env --daily
5 9 * * 1 /usr/local/bin/vps-traffic-monitor --config /etc/vps-traffic-monitor.env --weekly
10 9 1 * * /usr/local/bin/vps-traffic-monitor --config /etc/vps-traffic-monitor.env --monthly
```

## Configuration

Copy `vps-traffic-monitor.env.example` and set:

- `PUSH_CHANNEL=telegram` with `TG_BOT_TOKEN` and `TG_CHAT_ID`.
- `PUSH_CHANNEL=bark` with `BARK_URL`.
- `TRAFFIC_LIMIT_GB` for the monthly quota.
- `ALERT_PERCENT` for the warning threshold.
- `IFACE=auto` unless you need to pin a specific interface.
