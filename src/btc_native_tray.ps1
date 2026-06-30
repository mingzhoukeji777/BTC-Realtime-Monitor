# BTC实时通信系统 v1.1 - Binance U本位 + OKX 币本位
# UTF-8 BOM required for Windows PowerShell 5 Chinese UI.
$ErrorActionPreference = 'Continue'

try {
    $scriptPath = $MyInvocation.MyCommand.Path
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $exeName = [System.IO.Path]::GetFileName($exePath)
    if ($scriptPath -and $scriptPath.ToLower().EndsWith('.ps1')) {
        $BaseDir = Split-Path -Parent (Split-Path -Parent $scriptPath)
    } elseif ($exePath -and (Test-Path $exePath) -and ($exeName -notmatch 'powershell')) {
        $BaseDir = Split-Path -Parent $exePath
    } else {
        $BaseDir = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\\')
    }
    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Split-Path -Parent $scriptPath }
} catch { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$LogDir = Join-Path $BaseDir 'logs'
$DataDir = Join-Path $BaseDir 'data'
New-Item -ItemType Directory -Force -Path $LogDir, $DataDir | Out-Null
$LogFile = Join-Path $LogDir 'native_tray.log'
$SchemaVersion = '1.2.0'
$SnapshotDb = Join-Path $DataDir 'btc_collector.sqlite3'
$SqliteExe = Join-Path (Join-Path $BaseDir 'tools') 'sqlite3.exe'
$ConfigFile = Join-Path $BaseDir 'config.env'

function Write-AppLog([string]$Msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Encoding UTF8 -Value "[$ts] $Msg"
}

function Load-Config {
    $cfg = @{}
    if (Test-Path $ConfigFile) {
        Get-Content $ConfigFile -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
                $idx = $line.IndexOf('=')
                $k = $line.Substring(0, $idx).Trim()
                $v = $line.Substring($idx + 1).Trim()
                $cfg[$k] = $v
            }
        }
    }
    return $cfg
}

function Get-Cfg([hashtable]$cfg, [string]$key, [string]$default='') {
    if ($cfg.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($cfg[$key])) { return [string]$cfg[$key] }
    return $default
}

function HmacSHA256Hex([string]$secret, [string]$message) {
    $keyBytes = [Text.Encoding]::UTF8.GetBytes($secret)
    $msgBytes = [Text.Encoding]::UTF8.GetBytes($message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hash = $hmac.ComputeHash($msgBytes)
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function HmacSHA256Base64([string]$secret, [string]$message) {
    $keyBytes = [Text.Encoding]::UTF8.GetBytes($secret)
    $msgBytes = [Text.Encoding]::UTF8.GetBytes($message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    return [Convert]::ToBase64String($hmac.ComputeHash($msgBytes))
}

function UrlEncode([string]$s) { return [System.Uri]::EscapeDataString($s) }

function Invoke-JsonGet([string]$url, [hashtable]$headers=$null, [int]$timeout=4) {
    try {
        if ($headers) { return Invoke-RestMethod -Uri $url -TimeoutSec $timeout -Headers $headers -Method Get }
        return Invoke-RestMethod -Uri $url -TimeoutSec $timeout -Method Get -Headers @{ 'User-Agent' = 'BTC-Realtime-Monitor/1.1' }
    } catch {
        $detail = $_.Exception.Message
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message } } catch {}
        try {
            $resp = $_.Exception.Response
            if ($resp) {
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    if ($body) { $detail = $body }
                }
            }
        } catch {}
        throw $detail
    }
}

function Binance-SignedGet([string]$path, [hashtable]$params, [hashtable]$cfg) {
    $key = Get-Cfg $cfg 'BINANCE_API_KEY'
    $secret = Get-Cfg $cfg 'BINANCE_API_SECRET'
    if (-not $key -or -not $secret) { throw 'Binance API Key/Secret 未完整配置' }
    $base = 'https://fapi.binance.com'
    $server = Invoke-JsonGet ($base + '/fapi/v1/time')
    $params['timestamp'] = [string]$server.serverTime
    $params['recvWindow'] = '5000'
    $pairs = @()
    foreach ($k in ($params.Keys | Sort-Object)) { $pairs += ((UrlEncode $k) + '=' + (UrlEncode ([string]$params[$k]))) }
    $query = $pairs -join '&'
    $sig = HmacSHA256Hex $secret $query
    $url = $base + $path + '?' + $query + '&signature=' + $sig
    return Invoke-JsonGet $url @{ 'X-MBX-APIKEY' = $key; 'User-Agent'='BTC-Realtime-Monitor/1.1' }
}

function OKX-PrivateGet([string]$requestPath, [hashtable]$cfg) {
    $key = Get-Cfg $cfg 'OKX_API_KEY'
    $secret = Get-Cfg $cfg 'OKX_API_SECRET'
    $pass = Get-Cfg $cfg 'OKX_API_PASSPHRASE'
    if (-not $key -or -not $secret -or -not $pass) { throw 'OKX API Key/Secret/Passphrase 未完整配置' }
    $ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $method = 'GET'
    $body = ''
    $prehash = $ts + $method + $requestPath + $body
    $sign = HmacSHA256Base64 $secret $prehash
    $headers = @{
        'OK-ACCESS-KEY' = $key
        'OK-ACCESS-SIGN' = $sign
        'OK-ACCESS-TIMESTAMP' = $ts
        'OK-ACCESS-PASSPHRASE' = $pass
        'Content-Type' = 'application/json'
        'User-Agent' = 'BTC-Realtime-Monitor/1.1'
    }
    return Invoke-JsonGet ('https://www.okx.com' + $requestPath) $headers 4
}

function Format-Num($v, [int]$digits=2) {
    try {
        if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v) -or [string]$v -eq '--') { return '--' }
        $n = [double]([string]$v)
        return $n.ToString('N' + $digits)
    } catch { return '--' }
}

function Get-SnapshotCsvPath {
    $day = Get-Date -Format 'yyyy-MM-dd'
    return (Join-Path $DataDir ("exchange_snapshots_$day.csv"))
}

function Ensure-SnapshotFile([string]$path) {
    if (-not (Test-Path $path)) {
        'schema_version,ts,event_type,exchange,symbol,price,funding,equity,available,position,entry,mark,upnl,liq,open_orders,status,last_success,consecutive_failures' | Set-Content -Path $path -Encoding UTF8
    }
}

function SqlQuote([string]$s) {
    if ($null -eq $s) { return "''" }
    return "'" + ([string]$s).Replace("'", "''") + "'"
}

function Invoke-Sqlite([string]$sql) {
    if (-not (Test-Path $SqliteExe)) { return $false }
    try {
        $tmp = Join-Path $DataDir ('sqlite_' + [Guid]::NewGuid().ToString('N') + '.sql')
        Set-Content -Path $tmp -Encoding UTF8 -Value $sql
        & $SqliteExe $SnapshotDb ".read $tmp" | Out-Null
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-AppLog ('sqlite write failed: ' + $_.Exception.Message)
        return $false
    }
}

function Ensure-Database {
    $sql = @"
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  schema_version TEXT NOT NULL,
  ts TEXT NOT NULL,
  event_type TEXT NOT NULL,
  exchange TEXT NOT NULL,
  symbol TEXT,
  price TEXT,
  funding TEXT,
  equity TEXT,
  available TEXT,
  position TEXT,
  entry TEXT,
  mark TEXT,
  upnl TEXT,
  liq TEXT,
  open_orders TEXT,
  status TEXT,
  last_success TEXT,
  consecutive_failures INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_snapshots_ts_exchange ON snapshots(ts, exchange);
CREATE TABLE IF NOT EXISTS heartbeat (
  exchange TEXT PRIMARY KEY,
  schema_version TEXT NOT NULL,
  last_success TEXT,
  last_error TEXT,
  consecutive_failures INTEGER DEFAULT 0,
  updated_at TEXT NOT NULL
);
"@
    Invoke-Sqlite $sql | Out-Null
}

function Update-Health([string]$exchange, [bool]$ok, [string]$message='') {
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if (-not $script:health.ContainsKey($exchange)) {
        $script:health[$exchange] = [ordered]@{ last_success=''; last_error=''; consecutive_failures=0; updated_at=$now }
    }
    if ($ok) {
        $script:health[$exchange]['last_success'] = $now
        $script:health[$exchange]['last_error'] = ''
        $script:health[$exchange]['consecutive_failures'] = 0
    } else {
        $script:health[$exchange]['last_error'] = $message
        $script:health[$exchange]['consecutive_failures'] = [int]$script:health[$exchange]['consecutive_failures'] + 1
    }
    $script:health[$exchange]['updated_at'] = $now
}

function Write-Heartbeat {
    $hbPath = Join-Path $DataDir 'heartbeat.json'
    $obj = [ordered]@{ schema_version=$SchemaVersion; updated_at=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); exchanges=$script:health }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -Path $hbPath -Encoding UTF8
    if (Test-Path $SqliteExe) {
        $sql = ''
        foreach ($k in $script:health.Keys) {
            $h = $script:health[$k]
            $sql += "INSERT OR REPLACE INTO heartbeat(exchange,schema_version,last_success,last_error,consecutive_failures,updated_at) VALUES (" + (SqlQuote $k) + "," + (SqlQuote $SchemaVersion) + "," + (SqlQuote $h['last_success']) + "," + (SqlQuote $h['last_error']) + "," + ([int]$h['consecutive_failures']) + "," + (SqlQuote $h['updated_at']) + ");`n"
        }
        if ($sql) { Invoke-Sqlite $sql | Out-Null }
    }
}

function Persist-Snapshots([string]$eventType, [array]$snaps) {
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $csv = Get-SnapshotCsvPath
    Ensure-SnapshotFile $csv
    $sql = ''
    foreach ($s in $snaps) {
        $h = $script:health[$s.exchange]
        $lastSuccess = if ($h) { $h['last_success'] } else { '' }
        $fails = if ($h) { [int]$h['consecutive_failures'] } else { 0 }
        $csvLine = '"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}","{11}","{12}","{13}","{14}","{15}","{16}","{17}"' -f $SchemaVersion,$now,$eventType,$s.exchange,$s.symbol,$s.price,$s.funding,$s.equity,$s.available,$s.position,$s.entry,$s.mark,$s.upnl,$s.liq,$s.open_orders,($s.status -replace '"',''),$lastSuccess,$fails
        Add-Content -Path $csv -Encoding UTF8 -Value $csvLine
        $vals = @($SchemaVersion,$now,$eventType,$s.exchange,$s.symbol,$s.price,$s.funding,$s.equity,$s.available,$s.position,$s.entry,$s.mark,$s.upnl,$s.liq,$s.open_orders,($s.status -replace '"',''),$lastSuccess,[string]$fails)
        $sql += "INSERT INTO snapshots(schema_version,ts,event_type,exchange,symbol,price,funding,equity,available,position,entry,mark,upnl,liq,open_orders,status,last_success,consecutive_failures) VALUES (" + (($vals | ForEach-Object { SqlQuote $_ }) -join ',') + ");`n"
    }
    if ($sql) { Invoke-Sqlite $sql | Out-Null }
    Write-Heartbeat
}

function Get-BinanceSnapshot([hashtable]$cfg) {
    $symbol = Get-Cfg $cfg 'BINANCE_SYMBOL' 'BTCUSDT'
    $snap = [ordered]@{ exchange='Binance U本位'; symbol=$symbol; price='--'; funding='--'; equity='--'; available='--'; position='--'; entry='--'; mark='--'; upnl='--'; liq='--'; open_orders='--'; status='OK' }
    try {
        $ticker = Invoke-JsonGet "https://fapi.binance.com/fapi/v1/ticker/price?symbol=$symbol"
        $snap.price = [string]$ticker.price
        $premium = Invoke-JsonGet "https://fapi.binance.com/fapi/v1/premiumIndex?symbol=$symbol"
        $snap.funding = [string]([math]::Round(([double]$premium.lastFundingRate * 100), 5)) + '%'
        $snap.mark = [string]$premium.markPrice
    } catch { $snap.status = '公开接口失败：' + $_.Exception.Message }
    try {
        $account = Binance-SignedGet '/fapi/v2/account' @{} $cfg
        $snap.equity = [string]$account.totalWalletBalance
        $snap.available = [string]$account.availableBalance
        $posList = Binance-SignedGet '/fapi/v2/positionRisk' @{ symbol=$symbol } $cfg
        $pos = @($posList)[0]
        if ($pos) {
            $snap.position = [string]$pos.positionAmt
            $snap.entry = [string]$pos.entryPrice
            $snap.mark = [string]$pos.markPrice
            $snap.upnl = [string]$pos.unRealizedProfit
            $snap.liq = [string]$pos.liquidationPrice
        }
        $orders = Binance-SignedGet '/fapi/v1/openOrders' @{ symbol=$symbol } $cfg
        $snap.open_orders = [string](@($orders).Count)
    } catch {
        if ($snap.status -eq 'OK') { $snap.status = '私有接口未验证：' + $_.Exception.Message }
        else { $snap.status += '；私有接口未验证：' + $_.Exception.Message }
    }
    return $snap
}

function Get-OKXSnapshot([hashtable]$cfg) {
    $inst = Get-Cfg $cfg 'OKX_INST_ID' 'BTC-USD-SWAP'
    $snap = [ordered]@{ exchange='OKX 币本位'; symbol=$inst; price='--'; funding='--'; equity='--'; available='--'; position='--'; entry='--'; mark='--'; upnl='--'; liq='--'; open_orders='--'; status='OK' }
    try {
        $ticker = Invoke-JsonGet "https://www.okx.com/api/v5/market/ticker?instId=$inst"
        if ($ticker.data.Count -gt 0) { $snap.price = [string]$ticker.data[0].last }
        $fund = Invoke-JsonGet "https://www.okx.com/api/v5/public/funding-rate?instId=$inst"
        if ($fund.data.Count -gt 0) { $snap.funding = [string]([math]::Round(([double]$fund.data[0].fundingRate * 100), 5)) + '%' }
    } catch { $snap.status = '公开接口失败：' + $_.Exception.Message }
    try {
        $balance = OKX-PrivateGet '/api/v5/account/balance?ccy=BTC' $cfg
        if ($balance.data.Count -gt 0) {
            $detail = @($balance.data[0].details | Where-Object { $_.ccy -eq 'BTC' })[0]
            if ($detail) { $snap.equity = [string]$detail.eq; $snap.available = [string]$detail.availBal }
        }
        $positions = OKX-PrivateGet ("/api/v5/account/positions?instType=SWAP&instId=$inst") $cfg
        $posRows = @($positions.data)
        $pos = @($posRows | Where-Object { try { [double]$_.pos -ne 0 } catch { $false } } | Select-Object -First 1)[0]
        if (-not $pos -and $posRows.Count -gt 0) { $pos = $posRows[0] }
        if ($pos) {
            $side = [string]$pos.posSide
            $amount = [string]$pos.pos
            if ($side -and $side -ne 'net') { $snap.position = ($side + ' ' + $amount) }
            else { $snap.position = $amount }
            $snap.entry = [string]$pos.avgPx
            $snap.mark = [string]$pos.markPx
            $snap.upnl = [string]$pos.upl
            $snap.liq = [string]$pos.liqPx
        }
        $orders = OKX-PrivateGet ("/api/v5/trade/orders-pending?instId=$inst") $cfg
        $snap.open_orders = [string](@($orders.data).Count)
    } catch {
        if ($snap.status -eq 'OK') { $snap.status = '私有接口未验证：' + $_.Exception.Message }
        else { $snap.status += '；私有接口未验证：' + $_.Exception.Message }
    }
    return $snap
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\BTCRealtimeMultiExchange_XiaoZhu_v11', [ref]$createdNew)
if (-not $createdNew) { Write-AppLog '已有 v1.1 实例在运行，本次重复启动退出'; exit 0 }

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Ensure-Database
    Write-AppLog '程序启动：v1.2.0 数据采集版：分频刷新+SQLite+心跳'

    $cfg = Load-Config
    $priceSec = [int](Get-Cfg $cfg 'PRICE_REFRESH_SECONDS' '3')
    if ($priceSec -lt 1) { $priceSec = 1 }
    $accountSec = [int](Get-Cfg $cfg 'ACCOUNT_REFRESH_SECONDS' '10')
    if ($accountSec -lt 5) { $accountSec = 5 }
    $fundingSec = [int](Get-Cfg $cfg 'FUNDING_REFRESH_SECONDS' '60')
    if ($fundingSec -lt 30) { $fundingSec = 30 }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BTC实时通信系统 v1.2.0 数据采集版'
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(980, 650)
    $form.Size = New-Object System.Drawing.Size(1080, 720)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.Dock = [System.Windows.Forms.DockStyle]::Fill
    $main.Padding = New-Object System.Windows.Forms.Padding(16)
    $main.ColumnCount = 1
    $main.RowCount = 5
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 130))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $form.Controls.Add($main)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'BTC 多交易所实时监控：Binance U本位永续 + OKX BTC币本位永续'
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.Margin = New-Object System.Windows.Forms.Padding(0,0,0,10)
    $main.Controls.Add($title,0,0)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = '状态：启动中'
    $statusLabel.AutoSize = $true
    $statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $statusLabel.Margin = New-Object System.Windows.Forms.Padding(0,0,0,10)
    $main.Controls.Add($statusLabel,0,1)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.Columns.Add('exchange','交易所') | Out-Null
    $grid.Columns.Add('symbol','合约') | Out-Null
    $grid.Columns.Add('price','价格') | Out-Null
    $grid.Columns.Add('funding','资金费率') | Out-Null
    $grid.Columns.Add('equity','账户权益') | Out-Null
    $grid.Columns.Add('available','可用') | Out-Null
    $grid.Columns.Add('position','持仓') | Out-Null
    $grid.Columns.Add('entry','开仓均价') | Out-Null
    $grid.Columns.Add('mark','标记价') | Out-Null
    $grid.Columns.Add('upnl','未实现盈亏') | Out-Null
    $grid.Columns.Add('liq','强平价') | Out-Null
    $grid.Columns.Add('orders','挂单数') | Out-Null
    $grid.Columns.Add('status','状态') | Out-Null
    $main.Controls.Add($grid,0,2)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.Text = '等待接口数据……'
    $main.Controls.Add($logBox,0,3)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $buttonPanel.AutoSize = $false
    $buttonPanel.Height = 48
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonPanel.WrapContents = $false
    $buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0,12,0,0)
    $main.Controls.Add($buttonPanel,0,4)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = '立即刷新'
    $btnRefresh.MinimumSize = New-Object System.Drawing.Size(100,34)
    $buttonPanel.Controls.Add($btnRefresh)
    $btnHide = New-Object System.Windows.Forms.Button
    $btnHide.Text = '隐藏到托盘'
    $btnHide.MinimumSize = New-Object System.Drawing.Size(120,34)
    $btnHide.Margin = New-Object System.Windows.Forms.Padding(12,3,3,3)
    $buttonPanel.Controls.Add($btnHide)
    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = '退出程序'
    $btnExit.MinimumSize = New-Object System.Drawing.Size(100,34)
    $btnExit.Margin = New-Object System.Windows.Forms.Padding(12,3,3,3)
    $buttonPanel.Controls.Add($btnExit)

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.Text = 'BTC多交易所监控启动中'
    $notify.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $menu.Items.Add('显示窗口')
    $miHide = $menu.Items.Add('隐藏窗口')
    $miExit = $menu.Items.Add('退出程序')
    $notify.ContextMenuStrip = $menu

    $script:closingForExit = $false
    $script:health = @{}
    $script:lastSnaps = @{}
    $script:lastFundingRefresh = Get-Date '2000-01-01'
    function Add-Unit([string]$value, [string]$unit, [int]$digits=4) {
        $n = Format-Num $value $digits
        if ($n -eq '--') { return '--' }
        return ($n + ' ' + $unit)
    }
    function Format-PositionText([string]$exchange, [string]$value) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq '--') { return '--' }
        if ($exchange -like 'OKX*') {
            if ($value -like 'short *') { try { return ('空 ' + (Format-Num ([double]$value.Substring(6)) 4) + ' 张') } catch { return ('空 ' + $value.Substring(6) + ' 张') } }
            if ($value -like 'long *') { try { return ('多 ' + (Format-Num ([double]$value.Substring(5)) 4) + ' 张') } catch { return ('多 ' + $value.Substring(5) + ' 张') } }
            try {
                $n = [double]$value
                if ($n -gt 0) { return ('多 ' + (Format-Num $n 4) + ' 张') }
                if ($n -lt 0) { return ('空 ' + (Format-Num ([math]::Abs($n)) 4) + ' 张') }
                return '无 0 张'
            } catch { return ($value + ' 张') }
        } else {
            try {
                $n = [double]$value
                if ($n -gt 0) { return ('多 ' + (Format-Num $n 4) + ' BTC') }
                if ($n -lt 0) { return ('空 ' + (Format-Num ([math]::Abs($n)) 4) + ' BTC') }
                return '无 0 BTC'
            } catch { return $value }
        }
    }
    function Update-Grid([array]$snaps) {
        $grid.SuspendLayout()
        try {
            $grid.Rows.Clear()
            foreach ($s in $snaps) {
                if ($s.exchange -like 'OKX*') {
                    $equityText = Add-Unit $s.equity 'BTC' 4
                    $availText = Add-Unit $s.available 'BTC' 4
                    $posText = Format-PositionText $s.exchange $s.position
                    $upnlText = Add-Unit $s.upnl 'BTC' 4
                } else {
                    $equityText = Add-Unit $s.equity 'USDT' 1
                    $availText = Add-Unit $s.available 'USDT' 1
                    $posText = Format-PositionText $s.exchange $s.position
                    $upnlText = Add-Unit $s.upnl 'USDT' 1
                }
                $grid.Rows.Add($s.exchange,$s.symbol,(Format-Num $s.price 1),$s.funding,$equityText,$availText,$posText,(Format-Num $s.entry 1),(Format-Num $s.mark 1),$upnlText,(Format-Num $s.liq 1),$s.open_orders,$s.status) | Out-Null
            }
        } finally {
            $grid.ResumeLayout()
        }
    }
    function New-Snap([string]$exchange, [string]$symbol) {
        return [ordered]@{ exchange=$exchange; symbol=$symbol; price='--'; funding='--'; equity='--'; available='--'; position='--'; entry='--'; mark='--'; upnl='--'; liq='--'; open_orders='--'; status='启动中' }
    }
    function State-Key([string]$exchange) { return $exchange }
    function Save-State($snap) {
        $script:lastSnaps[(State-Key $snap.exchange)] = $snap
        $ok = ([string]$snap.status -eq 'OK')
        Update-Health $snap.exchange $ok ([string]$snap.status)
    }
    function Get-StateSnaps {
        $arr = @()
        foreach ($name in @('Binance U本位','OKX 币本位')) {
            if ($script:lastSnaps.ContainsKey($name)) { $arr += $script:lastSnaps[$name] }
        }
        return $arr
    }
    function Apply-State([string]$eventType) {
        $snaps = @(Get-StateSnaps)
        if ($snaps.Count -eq 0) { return }
        Update-Grid $snaps
        Persist-Snapshots $eventType $snaps
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $hb = ($snaps | ForEach-Object {
            $h = $script:health[$_.exchange]
            if ($h) { $_.exchange + ' 成功=' + $h['last_success'] + ' 失败=' + $h['consecutive_failures'] } else { $_.exchange + ' 等待' }
        }) -join ' ｜ '
        $statusLabel.Text = "状态：$eventType 已刷新｜$now｜$hb"
        $notify.Text = ('BTC采集器 ' + $now)
        $summary = ($snaps | ForEach-Object { $_.exchange + '=' + (Format-Num $_.price 1) + ' 资金=' + $_.funding }) -join ' | '
        $logBox.AppendText("`r`n[$now][$eventType] $summary")
        Write-AppLog ("refresh $eventType $summary")
    }
    function Ensure-InitialState {
        $cfg = Load-Config
        $binSym = Get-Cfg $cfg 'BINANCE_SYMBOL' 'BTCUSDT'
        $okxInst = Get-Cfg $cfg 'OKX_INST_ID' 'BTC-USD-SWAP'
        if (-not $script:lastSnaps.ContainsKey('Binance U本位')) { $script:lastSnaps['Binance U本位'] = New-Snap 'Binance U本位' $binSym }
        if (-not $script:lastSnaps.ContainsKey('OKX 币本位')) { $script:lastSnaps['OKX 币本位'] = New-Snap 'OKX 币本位' $okxInst }
    }
    function Refresh-Price([bool]$includeFunding=$false) {
        if ($script:refreshingPrice) { return }
        $script:refreshingPrice = $true
        try {
            Ensure-InitialState
            $cfg = Load-Config
            if ((Get-Cfg $cfg 'BINANCE_ENABLED' 'true') -ne 'false') {
                $symbol = Get-Cfg $cfg 'BINANCE_SYMBOL' 'BTCUSDT'
                $s = $script:lastSnaps['Binance U本位']
                $s.symbol = $symbol
                try {
                    $ticker = Invoke-JsonGet "https://fapi.binance.com/fapi/v1/ticker/price?symbol=$symbol" $null 3
                    $s.price = [string]$ticker.price
                    $premium = Invoke-JsonGet "https://fapi.binance.com/fapi/v1/premiumIndex?symbol=$symbol" $null 3
                    $s.mark = [string]$premium.markPrice
                    if ($includeFunding -or $s.funding -eq '--') { $s.funding = [string]([math]::Round(([double]$premium.lastFundingRate * 100), 5)) + '%' }
                    $s.status = 'OK'
                } catch { $s.status = '价格接口失败：' + $_.Exception.Message }
                Save-State $s
            }
            if ((Get-Cfg $cfg 'OKX_ENABLED' 'true') -ne 'false') {
                $inst = Get-Cfg $cfg 'OKX_INST_ID' 'BTC-USD-SWAP'
                $s = $script:lastSnaps['OKX 币本位']
                $s.symbol = $inst
                try {
                    $ticker = Invoke-JsonGet "https://www.okx.com/api/v5/market/ticker?instId=$inst" $null 3
                    if ($ticker.data.Count -gt 0) { $s.price = [string]$ticker.data[0].last }
                    if ($includeFunding -or $s.funding -eq '--') {
                        $fund = Invoke-JsonGet "https://www.okx.com/api/v5/public/funding-rate?instId=$inst" $null 3
                        if ($fund.data.Count -gt 0) { $s.funding = [string]([math]::Round(([double]$fund.data[0].fundingRate * 100), 5)) + '%' }
                    }
                    $s.status = 'OK'
                } catch { $s.status = '价格接口失败：' + $_.Exception.Message }
                Save-State $s
            }
            $evt = if ($includeFunding) { 'funding' } else { 'price' }
            Apply-State $evt
        } finally { $script:refreshingPrice = $false }
    }
    function Refresh-Account {
        if ($script:refreshingAccount) { return }
        $script:refreshingAccount = $true
        try {
            $cfg = Load-Config
            if ((Get-Cfg $cfg 'BINANCE_ENABLED' 'true') -ne 'false') { Save-State (Get-BinanceSnapshot $cfg) }
            if ((Get-Cfg $cfg 'OKX_ENABLED' 'true') -ne 'false') { Save-State (Get-OKXSnapshot $cfg) }
            Apply-State 'account'
        } catch {
            $msg = $_.Exception.Message
            $statusLabel.Text = '状态：账户刷新失败｜' + $msg
            $logBox.AppendText("`r`n[ERROR] " + $msg)
            Write-AppLog ('account refresh error ' + $msg)
        } finally { $script:refreshingAccount = $false }
    }
    function Refresh-All {
        Refresh-Price $true
        Refresh-Account
    }
    $script:refreshingPrice = $false
    $script:refreshingAccount = $false


    $showAction = { $form.Show(); $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $form.Activate(); Write-AppLog '显示窗口' }
    $hideAction = { $form.Hide(); $notify.BalloonTipTitle='BTC实时通信系统'; $notify.BalloonTipText='程序已隐藏到系统托盘'; $notify.ShowBalloonTip(1000); Write-AppLog '隐藏到托盘' }
    $exitAction = { Write-AppLog '用户退出程序'; $script:closingForExit=$true; try { $timerPrice.Stop(); $timerAccount.Stop(); $timerFunding.Stop() } catch {}; $notify.Visible=$false; $notify.Dispose(); $form.Close(); [System.Windows.Forms.Application]::Exit() }

    $miShow.add_Click($showAction); $miHide.add_Click($hideAction); $miExit.add_Click($exitAction)
    $notify.add_DoubleClick($showAction)
    $btnRefresh.add_Click({ Refresh-All })
    $btnHide.add_Click($hideAction)
    $btnExit.add_Click($exitAction)
    $form.add_Resize({ if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { & $hideAction } })
    $form.add_FormClosing({ if (-not $script:closingForExit -and $_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $_.Cancel=$true; & $hideAction } })

    $timerPrice = New-Object System.Windows.Forms.Timer
    $timerPrice.Interval = $priceSec * 1000
    $timerPrice.add_Tick({ Refresh-Price $false })
    $timerPrice.Start()

    $timerAccount = New-Object System.Windows.Forms.Timer
    $timerAccount.Interval = $accountSec * 1000
    $timerAccount.add_Tick({ Refresh-Account })
    $timerAccount.Start()

    $timerFunding = New-Object System.Windows.Forms.Timer
    $timerFunding.Interval = $fundingSec * 1000
    $timerFunding.add_Tick({ Refresh-Price $true })
    $timerFunding.Start()
    $notify.ShowBalloonTip(1200, 'BTC实时通信系统', 'v1.2.0 数据采集版已启动', [System.Windows.Forms.ToolTipIcon]::Info)
    Refresh-All
    Write-AppLog 'NotifyIcon Visible=True，进入消息循环 v1.2.0'
    [System.Windows.Forms.Application]::Run($form)
}
catch { Write-AppLog ('程序崩溃：' + $_.Exception.ToString()) }
finally {
    try { if ($notify) { $notify.Visible=$false; $notify.Dispose() } } catch {}
    try { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() } catch {}
    Write-AppLog '程序结束'
}
