# BTC实时通信系统

Windows 原生 BTC 多交易所数据采集器。

当前主线版本：`v2.1.0 C# / .NET 8 WinForms`。

## 定位

这个软件只负责数据采集，不负责策略、风控、交易管理、日报、Excel 管理等复杂功能。

后续管理软件或 Excel 可以读取：

```text
data\btc_collector.sqlite3
data\exchange_snapshots_YYYY-MM-DD.csv
data\heartbeat.json
```

## 技术方案

- 语言：C# / .NET 8 WinForms
- GUI：Windows 原生 WinForms
- 托盘：Windows 原生 NotifyIcon
- 实时价格：WebSocket
- 账户/持仓/挂单：REST 低频轮询
- 数据库：内置 SQLite
- 打包：框架依赖小体积单 EXE，不再内置 .NET 运行时

## 当前功能 v2.1.0

- 去掉标题栏和主标题里的技术说明文字，界面更简洁
- 表格按内容自动适应列宽，窗口启动时尽量适配屏幕工作区
- OKX 币本位张数显示 1 位小数
- 开机自启动复选框，默认勾选
- 开机自启动时自动最小化到托盘
- Binance BTC U本位永续 `BTCUSDT`
  - WebSocket 实时价格/标记价
  - 资金费率
  - 账户权益、持仓、挂单，只读 REST
- OKX BTC 币本位永续 `BTC-USD-SWAP`
  - WebSocket 实时价格
  - WebSocket/REST 资金费率
  - 账户权益、持仓、挂单，只读 REST
- SQLite 数据库：

```text
data\btc_collector.sqlite3
```

- CSV 按日期分文件：

```text
data\exchange_snapshots_2026-06-30.csv
```

- 心跳文件：

```text
data\heartbeat.json
```

- 自动清理历史数据，默认保留 30 天
- 所有数据带 `schema_version=2.1.0`

## 运行环境

v2.1.0 开始，为了减小体积，EXE 不再内置 .NET。

这台电脑已经安装：

```text
.NET 8 Desktop Runtime / SDK
```

所以可以直接双击运行。

如果换到另一台没有 .NET 8 的电脑，需要安装：

```text
Microsoft .NET 8 Desktop Runtime x64
```

## 显示规则

GUI 显示：

```text
实时价格 / 标记价 / 强平价：1 位小数
BTC 金额：4 位小数
U本位 USDT 金额：1 位小数
OKX 张数：1 位小数
持仓：多/空 + 单位
```

CSV 和 SQLite 保留接口原始值，方便 Excel 或管理软件做精确计算。

## 配置

复制：

```text
config.env.example -> config.env
```

填写本地 API Key。`config.env` 不要上传 GitHub。

示例：

```env
BINANCE_ENABLED=true
BINANCE_API_KEY=
BINANCE_API_SECRET=
BINANCE_SYMBOL=BTCUSDT

OKX_ENABLED=true
OKX_API_KEY=
OKX_API_SECRET=
OKX_API_PASSPHRASE=
OKX_INST_ID=BTC-USD-SWAP

PRICE_REFRESH_SECONDS=3
ACCOUNT_REFRESH_SECONDS=10
FUNDING_REFRESH_SECONDS=60
RETENTION_DAYS=30
```

## API 权限建议

只开：

```text
Read / 读取
```

不要开：

```text
Trade / 交易
Withdraw / 提现
```

如果电脑公网 IP 不固定，OKX API Key 可以不绑定 IP 白名单，但务必只开只读权限。

## 运行方式

直接双击：

```text
BTC实时通信系统.exe
```

开机自启动由界面底部复选框控制，默认勾选。自启动时会自动最小化到托盘。

## 数据清理

默认保留最近 30 天：

```env
RETENTION_DAYS=30
```

清理内容：

- SQLite `snapshots` 表中过期快照
- 过期的按日 CSV 文件

不会清理：

- `config.env`
- 当天数据
- heartbeat 当前状态
