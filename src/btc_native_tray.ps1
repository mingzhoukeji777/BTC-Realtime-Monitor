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
$SnapshotCsv = Join-Path $DataDir 'exchange_snapshots.csv'
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

function Ensure-SnapshotFile {
    if (-not (Test-Path $SnapshotCsv)) {
        'ts,exchange,symbol,price,funding,equity,available,position,entry,mark,upnl,liq,open_orders,status' | Set-Content -Path $SnapshotCsv -Encoding UTF8
    }
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
    Ensure-SnapshotFile
    Write-AppLog '程序启动：v1.1.4 数据采集版 + 四位小数显示'

    $cfg = Load-Config
    $priceSec = [int](Get-Cfg $cfg 'PRICE_REFRESH_SECONDS' '10')
    if ($priceSec -lt 5) { $priceSec = 5 }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BTC实时通信系统 v1.1.4 数据采集版'
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
    function Add-Unit([string]$value, [string]$unit, [int]$digits=4) {
        $n = Format-Num $value $digits
        if ($n -eq '--') { return '--' }
        return ($n + ' ' + $unit)
    }
    function Format-PositionText([string]$exchange, [string]$value) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq '--') { return '--' }
        if ($exchange -like 'OKX*') {
            if ($value -like 'short *') { return ('空 ' + $value.Substring(6) + ' 张') }
            if ($value -like 'long *') { return ('多 ' + $value.Substring(5) + ' 张') }
            try {
                $n = [double]$value
                if ($n -gt 0) { return ('多 ' + $value + ' 张') }
                if ($n -lt 0) { return ('空 ' + ([math]::Abs($n)).ToString() + ' 张') }
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
                    $equityText = Add-Unit $s.equity 'USDT' 4
                    $availText = Add-Unit $s.available 'USDT' 4
                    $posText = Format-PositionText $s.exchange $s.position
                    $upnlText = Add-Unit $s.upnl 'USDT' 4
                }
                $grid.Rows.Add($s.exchange,$s.symbol,(Format-Num $s.price 4),$s.funding,$equityText,$availText,$posText,(Format-Num $s.entry 4),(Format-Num $s.mark 4),$upnlText,(Format-Num $s.liq 4),$s.open_orders,$s.status) | Out-Null
            }
        } finally {
            $grid.ResumeLayout()
        }
    }
    function Refresh-All {
        if ($script:refreshing) { return }
        $script:refreshing = $true
        $statusLabel.Text = '状态：刷新中……'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $cfg = Load-Config
            $snaps = @()
            if ((Get-Cfg $cfg 'BINANCE_ENABLED' 'true') -ne 'false') { $snaps += (Get-BinanceSnapshot $cfg) }
            if ((Get-Cfg $cfg 'OKX_ENABLED' 'true') -ne 'false') { $snaps += (Get-OKXSnapshot $cfg) }
            Update-Grid $snaps
            foreach ($s in $snaps) {
                $csvLine = '"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}","{11}","{12}","{13}"' -f $now,$s.exchange,$s.symbol,$s.price,$s.funding,$s.equity,$s.available,$s.position,$s.entry,$s.mark,$s.upnl,$s.liq,$s.open_orders,($s.status -replace '"','')
                Add-Content -Path $SnapshotCsv -Encoding UTF8 -Value $csvLine
            }
            $statusLabel.Text = "状态：已刷新｜$now｜优化版：默认10秒刷新，网络超时缩短"
            $notify.Text = ('BTC监控 ' + $now)
            $summary = ($snaps | ForEach-Object { $_.exchange + '=' + (Format-Num $_.price 2) + ' funding=' + $_.funding }) -join ' | '
            $logBox.AppendText("`r`n[$now] $summary")
            Write-AppLog ("refresh $summary")
        } catch {
            $msg = $_.Exception.Message
            $statusLabel.Text = '状态：刷新失败｜' + $msg
            $logBox.AppendText("`r`n[ERROR] " + $msg)
            Write-AppLog ('refresh error ' + $msg)
        } finally {
            $script:refreshing = $false
        }
    }
    $script:refreshing = $false


    $showAction = { $form.Show(); $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $form.Activate(); Write-AppLog '显示窗口' }
    $hideAction = { $form.Hide(); $notify.BalloonTipTitle='BTC实时通信系统'; $notify.BalloonTipText='程序已隐藏到系统托盘'; $notify.ShowBalloonTip(1000); Write-AppLog '隐藏到托盘' }
    $exitAction = { Write-AppLog '用户退出程序'; $script:closingForExit=$true; $timer.Stop(); $notify.Visible=$false; $notify.Dispose(); $form.Close(); [System.Windows.Forms.Application]::Exit() }

    $miShow.add_Click($showAction); $miHide.add_Click($hideAction); $miExit.add_Click($exitAction)
    $notify.add_DoubleClick($showAction)
    $btnRefresh.add_Click({ Refresh-All })
    $btnHide.add_Click($hideAction)
    $btnExit.add_Click($exitAction)
    $form.add_Resize({ if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { & $hideAction } })
    $form.add_FormClosing({ if (-not $script:closingForExit -and $_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $_.Cancel=$true; & $hideAction } })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $priceSec * 1000
    $timer.add_Tick({ Refresh-All })
    $timer.Start()
    $notify.ShowBalloonTip(1200, 'BTC实时通信系统', 'v1.1.4 数据采集版已启动', [System.Windows.Forms.ToolTipIcon]::Info)
    Refresh-All
    Write-AppLog 'NotifyIcon Visible=True，进入消息循环 v1.1.4'
    [System.Windows.Forms.Application]::Run($form)
}
catch { Write-AppLog ('程序崩溃：' + $_.Exception.ToString()) }
finally {
    try { if ($notify) { $notify.Visible=$false; $notify.Dispose() } } catch {}
    try { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() } catch {}
    Write-AppLog '程序结束'
}
