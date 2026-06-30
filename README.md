# BTC实时通信系统

Windows 原生系统托盘 BTC 多交易所实时监控工具。

## 当前功能 v1.1

- 中文 GUI 界面
- Windows 原生系统托盘图标
- 隐藏到托盘 / 托盘恢复 / 退出程序
- Binance BTC U本位永续 `BTCUSDT`
  - 实时价格
  - 标记价格
  - 资金费率
  - 账户权益（需要 API Secret）
  - 当前持仓（需要 API Secret）
  - 当前挂单（需要 API Secret）
- OKX BTC 币本位永续 `BTC-USD-SWAP`
  - 实时价格
  - 资金费率
  - 账户权益（需要 API Key/Secret/Passphrase）
  - 当前持仓（需要 API Key/Secret/Passphrase）
  - 当前挂单（需要 API Key/Secret/Passphrase）
- 本地 CSV 记录快照
- 已打包为 EXE，可直接双击运行，不需要 BAT

## 运行方式

直接双击：

```text
BTC实时通信系统.exe
```

运行后会自动创建：

```text
data\exchange_snapshots.csv
logs\native_tray.log
```

## 配置

复制或参考：

```text
config.env.example
```

本地创建/编辑：

```text
config.env
```

注意：`config.env` 不上传 GitHub。

## 当前验证状态

已验证：

- Binance U本位 BTCUSDT 公开价格正常
- Binance U本位资金费率正常
- OKX BTC-USD-SWAP 公开价格正常
- OKX BTC-USD-SWAP 资金费率正常
- GUI 正常
- 系统托盘正常

等待密钥验证/账户侧条件：

- Binance 账户权益、持仓、挂单：当前签名认证已通；如果权益/持仓为空，通常表示该 API Key 对应账户没有 U本位合约资产/持仓，或不是实际交易子账户。
- OKX 账户权益、持仓、挂单：如返回 `50110`，需要把当前出口 IP 加入 OKX API Key 的 IP 白名单。

## OKX 常见错误

```text
code 50110: 当前出口 IP 不在 OKX API Key 白名单
```

解决：如果这台电脑公网 IP 不固定，不要把当前 IP 写死到白名单；可以在 OKX API 管理页面取消该 API Key 的 IP 白名单限制，或重新创建一个**只读权限**且不绑定固定 IP 的 API Key。务必只开启 Read/读取权限，不要开启 Trade/交易 或 Withdraw/提现。

## 源码

```text
src/btc_native_tray.ps1
```

## 安全说明

不要把真实 API Key / Secret 上传到 GitHub。
