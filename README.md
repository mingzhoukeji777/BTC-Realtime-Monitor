# BTC实时通信系统

Windows 原生 BTC 多交易所数据采集器。

当前主线版本：`v2.3.0 C# / .NET 8 WinForms`。

## 定位

这个软件只负责数据采集，不负责策略、风控、交易管理、日报、Excel 管理等复杂功能。

后续管理软件或 Excel 可以读取：

```text
data\btc_collector.sqlite3
data\exchange_snapshots_YYYY-MM-DD.csv
data\heartbeat.json
data\latest_snapshot.json
```

## 当前功能 v2.3.0

- 窗口改回紧凑尺寸，不再默认占满屏幕
- 表格按窗口宽度自适应，隐藏横向滚动条
- 日志区高度适中，初始连接信息不用横向滑动查看
- 价格、张数、BTC/USDT 金额显示去掉千分位逗号
- OKX 币本位张数显示 1 位小数
- 配置界面：可修改 API、合约、刷新频率、数据保留天数、数据输出目录
- 配置界面里支持 Binance / OKX 测试连接
- 主界面支持“打开数据目录”
- 状态列颜色：正常绿色、异常红色
- 托盘图标颜色：正常绿色、异常红色
- 托盘悬浮摘要：显示 Binance/OKX 价格和整体状态
- 固定最新快照文件：`latest_snapshot.json`
- 自动清理旧构建/临时发布文件
- 数据保留天数限制为 7–30 天
- 开机自启动复选框，默认勾选；自启动后自动最小化到托盘

## 技术方案

- 语言：C# / .NET 8 WinForms
- 实时价格：WebSocket
- 账户/持仓/挂单：REST 低频轮询
- 数据库：内置 SQLite
- 打包：框架依赖小体积单 EXE，不内置 .NET 运行时

## 运行环境

这台电脑已经安装 `.NET 8 Desktop Runtime / SDK`，可直接双击运行。

如果换到另一台没有 .NET 8 的电脑，需要安装：

```text
Microsoft .NET 8 Desktop Runtime x64
```

## 显示规则

```text
实时价格 / 标记价 / 强平价：1 位小数，无千分位逗号
BTC 金额：4 位小数，无千分位逗号
U本位 USDT 金额：1 位小数，无千分位逗号
OKX 张数：1 位小数，无千分位逗号
持仓：多/空 + 单位
```

CSV 和 SQLite 保留接口原始值，方便 Excel 或管理软件做精确计算。

## 配置

可以点击程序底部：

```text
配置
```

也可以手动编辑：

```text
config.env
```

主要配置：

```env
PRICE_REFRESH_SECONDS=3
ACCOUNT_REFRESH_SECONDS=10
FUNDING_REFRESH_SECONDS=60
DATA_OUTPUT_DIR=
RETENTION_DAYS=30
```

`DATA_OUTPUT_DIR` 留空表示程序所在目录；填写路径后，会在该目录下生成：

```text
data\
logs\
```

## 文件说明

最终本地保留：

```text
BTC实时通信系统.exe       主程序
config.env               本地密钥配置，不上传GitHub
config.env.example       配置模板
README.md                使用说明
csharp\BtcCollector\     C#源码，方便以后维护
.gitignore               Git忽略规则
```

运行时自动生成：

```text
data\
logs\
```

`data` 和 `logs` 是运行数据，不是安装依赖；删除后下次运行会自动重新生成。

## API 权限建议

只开 `Read / 读取`，不要开 `Trade / 交易` 或 `Withdraw / 提现`。

如果电脑公网 IP 不固定，OKX API Key 可以不绑定 IP 白名单，但务必只开只读权限。

## 数据清理

默认保留最近 30 天，可在配置界面设置，范围 7–30 天。

自动清理内容：

- SQLite `snapshots` 表中过期快照
- 过期按日 CSV
- 旧构建/临时发布目录
- 临时 release 文件

不会清理：

- `config.env`
- 当天数据
- `heartbeat.json` 当前状态
- `latest_snapshot.json`
- C# 源码
