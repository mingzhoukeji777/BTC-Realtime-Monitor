# BTC实时通信系统

Windows 原生系统托盘 BTC 实时价格监控工具。

## 当前功能

- 中文 GUI 界面
- Windows 原生系统托盘图标
- 隐藏到托盘 / 托盘恢复 / 退出程序
- 每 3 秒获取 Binance BTCUSDT 最新价格
- 本地 CSV 记录价格
- 已打包为 EXE，可直接双击运行，不需要 BAT

## 运行方式

直接双击：

```text
BTC实时通信系统.exe
```

运行后会自动创建：

```text
data\btc_price_ticks_native.csv
logs\native_tray.log
```

## 当前通信状态

已验证：

- Binance BTCUSDT 价格获取正常
- GUI 正常
- 系统托盘正常
- EXE 正常运行

尚未接入：

- 订单获取
- 仓位获取
- 账户权益获取

这些需要完整 Binance API Key + Secret，并且需要确认接入 U本位合约还是现货账户。

## 源码

源码文件：

```text
src/btc_native_tray.ps1
```

## 安全说明

不要把真实 API Key / Secret 上传到 GitHub。

本仓库默认忽略：

```text
config.env
logs/
data/
*.csv
*.sqlite3
```
