# vps-traffic-guard

轻量级 VPS 流量监控脚本，适配普通 Linux VPS 和甲骨文 Oracle Cloud VPS。

脚本从 `/sys/class/net` 读取网卡 RX/TX 计数，按月统计上传+下载总流量，并通过 Telegram Bot 或 Bark 推送告警、日报、周报、月报。

## 功能

- Bash 实现，无需 Python。
- 一键中文交互安装。
- 自动识别主网卡，普通 VPS / 甲骨文 VPS 默认用 `auto` 即可。
- 支持 Telegram Bot 或 Bark 二选一推送。
- 到达月流量阈值时告警，默认 `80%`。
- 超过 `100%` 时再次告警。
- 支持自定义日报、周报、月报推送时间。
- 不监听入站端口，不需要开放 VPS 防火墙端口。
- 只需要 VPS 能出站访问 HTTPS `443`，用于 Telegram/Bark 推送。
- 状态文件只保存流量计数和告警状态，不保存额外密钥副本。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ORyong/vps-traffic-guard/master/install.sh)
```

安装器会一步一步询问：

- 服务器名称（用于通知展示）。
- 月流量限额 GiB。
- 告警阈值百分比。
- 监控哪个网卡，默认 `auto`。
- 时区，默认 `Asia/Shanghai`。
- 确认端口/网络：不监听入站端口，只需要出站 HTTPS `443`。
- 告警检查频率：每小时或每 30 分钟。
- 日报推送时间。
- 周报推送日和推送时间。
- 月报推送日期和推送时间。
- 推送方式：Telegram Bot 或 Bark。
- Telegram Bot token/chat id，或 Bark URL。

安装完成后会写入 `/etc/vps-traffic-monitor.env`，安装命令到 `/usr/local/bin/vps-traffic-monitor`，添加 cron，并立即测试推送。

## 手动安装

```bash
sudo install -m 755 vps-traffic-monitor.sh /usr/local/bin/vps-traffic-monitor
sudo install -m 600 vps-traffic-monitor.env.example /etc/vps-traffic-monitor.env
sudo editor /etc/vps-traffic-monitor.env
```

测试推送：

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --test-push
```

测试流量读取，不真实推送：

```bash
vps-traffic-monitor --config /etc/vps-traffic-monitor.env --dry-run --check
```

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
