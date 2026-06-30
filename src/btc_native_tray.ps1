# BTC实时通信系统 - Windows原生托盘中文版
# 注意：本文件由 Python 以 UTF-8 BOM 写入，兼容 Windows PowerShell 5 中文解析。
$ErrorActionPreference = 'Continue'
try {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exePath -and (Test-Path $exePath)) {
        $BaseDir = Split-Path -Parent $exePath
    } else {
        $BaseDir = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
    }
    if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
} catch {
    $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$LogDir = Join-Path $BaseDir 'logs'
$DataDir = Join-Path $BaseDir 'data'
New-Item -ItemType Directory -Force -Path $LogDir, $DataDir | Out-Null
$LogFile = Join-Path $LogDir 'native_tray.log'
$CsvFile = Join-Path $DataDir 'btc_price_ticks_native.csv'
$Symbol = 'BTCUSDT'
$PriceUrl = 'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT'

function Write-AppLog([string]$Msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Encoding UTF8 -Value "[$ts] $Msg"
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\BTCRealtimeNativeTray_XiaoZhu_CN_v1', [ref]$createdNew)
if (-not $createdNew) {
    Write-AppLog '已有中文原生托盘实例在运行，本次重复启动退出'
    exit 0
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-AppLog '程序启动：Windows原生NotifyIcon中文版'

    if (-not (Test-Path $CsvFile)) {
        'ts_local,source,symbol,price' | Set-Content -Path $CsvFile -Encoding UTF8
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BTC实时通信系统'
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $form.Size = New-Object System.Drawing.Size(760, 560)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.TopMost = $false

    $main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.Dock = [System.Windows.Forms.DockStyle]::Fill
    $main.Padding = New-Object System.Windows.Forms.Padding(18)
    $main.ColumnCount = 1
    $main.RowCount = 7
    $main.AutoSize = $false
    $main.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 135))) | Out-Null
    $main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $form.Controls.Add($main)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'BTCUSDT 实时价格监控'
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $title.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $main.Controls.Add($title, 0, 0)

    $priceLabel = New-Object System.Windows.Forms.Label
    $priceLabel.Text = '--'
    $priceLabel.AutoSize = $true
    $priceLabel.Font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
    $priceLabel.ForeColor = [System.Drawing.Color]::FromArgb(23,54,93)
    $priceLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $main.Controls.Add($priceLabel, 0, 1)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = '状态：启动中，正在连接 Binance 行情接口……'
    $statusLabel.AutoSize = $true
    $statusLabel.MaximumSize = New-Object System.Drawing.Size(560, 0)
    $statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $main.Controls.Add($statusLabel, 0, 2)

    $sourceLabel = New-Object System.Windows.Forms.Label
    $sourceLabel.Text = '数据源：Binance Spot API｜刷新频率：3 秒｜本地记录：CSV'
    $sourceLabel.AutoSize = $true
    $sourceLabel.MaximumSize = New-Object System.Drawing.Size(560, 0)
    $sourceLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $sourceLabel.ForeColor = [System.Drawing.Color]::FromArgb(80,80,80)
    $sourceLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $main.Controls.Add($sourceLabel, 0, 3)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = '使用说明：点击“隐藏到托盘”后，窗口会收起到右下角系统托盘。若没有直接看到图标，请点击任务栏右侧 “^” 隐藏图标区域。双击托盘图标可恢复窗口，右键可显示/隐藏/退出。'
    $hintLabel.AutoSize = $true
    $hintLabel.MaximumSize = New-Object System.Drawing.Size(560, 0)
    $hintLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $hintLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $main.Controls.Add($hintLabel, 0, 4)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.MinimumSize = New-Object System.Drawing.Size(620, 120)
    $logBox.Height = 125
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.Text = "等待第一条价格数据……"
    $main.Controls.Add($logBox, 0, 5)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $buttonPanel.AutoSize = $false
    $buttonPanel.Height = 48
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonPanel.WrapContents = $false
    $buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0, 16, 0, 0)
    $main.Controls.Add($buttonPanel, 0, 6)

    $btnHide = New-Object System.Windows.Forms.Button
    $btnHide.Text = '隐藏到托盘'
    $btnHide.AutoSize = $true
    $btnHide.MinimumSize = New-Object System.Drawing.Size(120, 34)
    $buttonPanel.Controls.Add($btnHide)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = '退出程序'
    $btnExit.AutoSize = $true
    $btnExit.MinimumSize = New-Object System.Drawing.Size(100, 34)
    $btnExit.Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 3)
    $buttonPanel.Controls.Add($btnExit)

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.Text = 'BTC实时通信系统 启动中'
    $notify.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $menu.Items.Add('显示窗口')
    $miHide = $menu.Items.Add('隐藏窗口')
    $miExit = $menu.Items.Add('退出程序')
    $notify.ContextMenuStrip = $menu

    $script:closingForExit = $false
    $showAction = {
        $form.Show()
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Activate()
        Write-AppLog '显示窗口'
    }
    $hideAction = {
        $form.Hide()
        $notify.BalloonTipTitle = 'BTC实时通信系统'
        $notify.BalloonTipText = '程序已隐藏到系统托盘，双击图标可恢复窗口。'
        $notify.ShowBalloonTip(1200)
        Write-AppLog '隐藏到托盘'
    }
    $exitAction = {
        Write-AppLog '用户退出程序'
        $script:closingForExit = $true
        $timer.Stop()
        $notify.Visible = $false
        $notify.Dispose()
        $form.Close()
        [System.Windows.Forms.Application]::Exit()
    }

    $miShow.add_Click($showAction)
    $miHide.add_Click($hideAction)
    $miExit.add_Click($exitAction)
    $notify.add_DoubleClick($showAction)
    $btnHide.add_Click($hideAction)
    $btnExit.add_Click($exitAction)
    $form.add_Resize({ if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { & $hideAction } })
    $form.add_FormClosing({
        if (-not $script:closingForExit -and $_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $_.Cancel = $true
            & $hideAction
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({
        try {
            $resp = Invoke-RestMethod -Uri $PriceUrl -TimeoutSec 8 -Headers @{ 'User-Agent' = 'BTC-Native-Tray-CN/1.0' }
            $price = [double]$resp.price
            $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $priceText = ('{0:N2}' -f $price)
            $priceLabel.Text = $priceText
            $statusLabel.Text = "状态：实时通信正常｜更新时间：$now"
            $tip = "BTC $priceText | $now"
            if ($tip.Length -gt 63) { $tip = $tip.Substring(0,63) }
            $notify.Text = $tip
            Add-Content -Path $CsvFile -Encoding UTF8 -Value "$now,binance_spot,$Symbol,$price"
            $line = "[$now] BTCUSDT = $priceText"
            $logBox.AppendText("`r`n" + $line)
            Write-AppLog "price $Symbol $price"
        } catch {
            $msg = $_.Exception.Message
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0,120) }
            $statusLabel.Text = "状态：价格获取失败｜$msg"
            $logBox.AppendText("`r`n价格获取失败：$msg")
            Write-AppLog "价格获取失败：$msg"
        }
    })

    $timer.Start()
    $notify.ShowBalloonTip(1200, 'BTC实时通信系统', '原生托盘图标已启动', [System.Windows.Forms.ToolTipIcon]::Info)
    Write-AppLog 'NotifyIcon Visible=True，进入消息循环（中文版）'
    [System.Windows.Forms.Application]::Run($form)
}
catch {
    Write-AppLog ('程序崩溃：' + $_.Exception.ToString())
}
finally {
    try { if ($notify) { $notify.Visible = $false; $notify.Dispose() } } catch {}
    try { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() } catch {}
    Write-AppLog '程序结束'
}
