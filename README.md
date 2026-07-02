# vps-traffic-guard

轻量级 VPS 流量监控脚本，适配普通 Linux VPS 和甲骨文 Oracle Cloud VPS。

脚本从 `/sys/class/net` 读取网卡 RX/TX 计数，按月统计上传+下载总流量，并通过 Telegram Bot 或 Bark 推送告警、日报、周报、月报。

## 功能

- Bash 实现，无需 Python。
- 一键中文安装向导。
- 自动识别主网卡，普通 VPS / 甲骨文 VPS 默认用 `auto` 即可。
- 支持 Telegram Bot 或 Bark 二选一推送。
- 到达月流量阈值时告警，默认 `80%`。
- 超过 `100%` 时再次告警。
- 支持自定义日报、周报、月报推送时间。
- 支持完整 `vtg` 控制菜单：报告、检查、测试、配置、cron、升级、重配、卸载。
- 支持升级：重新运行安装命令，选择“升级脚本并保留配置”。
- 支持立即推送综合流量报告。
- 不监听入站端口，不需要开放 VPS 防火墙端口。
- 只需要 VPS 能出站访问 HTTPS `443`，用于 Telegram/Bark 推送。

## 一键安装 / 升级

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ORyong/vps-traffic-guard/master/install.sh)
```

首次安装会进入中文向导。若检测到已有安装，会提供：

- `1`：升级脚本并保留配置。
- `2`：重新配置并覆盖 vps-traffic-guard 管理的 cron。
- `3`：退出。

安装完成后会写入 `/etc/vps-traffic-monitor.env`，安装：

- `/usr/local/bin/vps-traffic-monitor`：主监控命令。
- `/usr/local/bin/vtg`：交互菜单命令。

## 常用命令

打开完整控制菜单：

```bash
vtg
```

立即推送综合报告：

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --report
```

测试推送通道：

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --test-push
```

测试流量读取，不真实推送：

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --dry-run --check
```

## 安装器会询问

- 服务器名称（用于通知展示）。
- 月流量限额 GiB。
- 告警阈值百分比。
- 监控网卡，默认 `auto`。
- 时区，默认 `Asia/Shanghai`。
- 端口/网络确认：不监听入站端口，只需要出站 HTTPS `443`。
- 告警检查间隔：每小时或每 30 分钟。
- 日报推送时间。
- 周报推送日和推送时间。
- 月报推送日期和推送时间。
- 推送通道：Telegram Bot 或 Bark。
- Telegram Bot token/chat id，或 Bark URL。

## 配置项

复制 `vps-traffic-monitor.env.example` 后配置：

- `VPS_NAME`：通知里显示的 VPS 名称。
- `PUSH_CHANNEL=telegram`：使用 Telegram Bot。
- `TG_BOT_TOKEN` 和 `TG_CHAT_ID`：Telegram 推送信息。
- `PUSH_CHANNEL=bark`：使用 Bark。
- `BARK_URL`：Bark 地址，支持自建端口，例如 `https://push.example.com:8080/KEY`。
- `TRAFFIC_LIMIT_GB`：月流量限额，单位 GiB。
- `ALERT_PERCENT`：告警百分比。
- `IFACE=auto`：自动识别主网卡；也可以指定 `ens3`、`eth0` 等。