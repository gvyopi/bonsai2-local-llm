#requires -Version 7.0
<#
  llmctl-gui.ps1 — WinForms 界面（由 llmctl.ps1 的 gui 子命令加载）

  关键约定：
    1. 事件处理器**不使用** GetNewClosure()。它会新建模块作用域，导致 $script:* 失效。
       改用 $sender.Tag 定位模型，状态变量统一放在 $script: 里。
    2. UI 线程不做 I/O：状态由后台 runspace 采集，UI 只读 $sync.Status。
    3. 只在数据变化时重绘，并开启双缓冲，避免闪烁。
#>

function Start-LlmGui {
    param([switch]$SelfTest, [switch]$ClickTest)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware)
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $ErrorActionPreference = 'Continue'

    $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = $g0.DpiX / 96.0
    $g0.Dispose()
    function S([double]$v) { [int][math]::Round($v * $script:Scale) }

    $script:C = @{
        Bg     = [System.Drawing.Color]::FromArgb(247, 248, 250)
        Card   = [System.Drawing.Color]::White
        Border = [System.Drawing.Color]::FromArgb(226, 229, 234)
        Text   = [System.Drawing.Color]::FromArgb(31, 35, 41)
        Sub    = [System.Drawing.Color]::FromArgb(107, 114, 128)
        Green  = [System.Drawing.Color]::FromArgb(46, 158, 91)
        Yellow = [System.Drawing.Color]::FromArgb(217, 162, 27)
        Gray   = [System.Drawing.Color]::FromArgb(154, 160, 166)
        Blue   = [System.Drawing.Color]::FromArgb(76, 141, 246)
        BarBg  = [System.Drawing.Color]::FromArgb(233, 236, 241)
    }
    $C = $script:C

    $script:ErrLog = Join-Path $LogDir 'gui-error.log'
    function Write-GuiError([string]$where, $err) {
        try {
            $m = "{0} [{1}] {2}`n{3}" -f (Get-Date -Format 'HH:mm:ss'), $where, $err.Exception.Message, $err.ScriptStackTrace
            Add-Content -LiteralPath $script:ErrLog -Value $m -Encoding UTF8
        } catch { }
    }

    # ---------------------------------------------------------------- 共享状态

    $sync = [hashtable]::Synchronized(@{ Status = $null; Cmd = $null; Res = $null; Stop = $false; WorkerError = $null })

    $script:Sync     = $sync
    $script:BusyKey  = $null
    $script:OllamaOk = $false
    $script:View     = @()
    $script:Gpu      = @{ Used = 0.0; Total = 8.0 }
    $script:CardRefs = [ordered]@{}
    $script:Closing  = $false
    $script:LastKey  = ''
    $script:SelfTestMode = [bool]$SelfTest

    $corePath = Join-Path $PSScriptRoot 'llmctl-core.ps1'

    $worker = {
        param($sync, $corePath, $intervalMs)
        try { . $corePath } catch { $sync.WorkerError = "核心层加载失败: $($_.Exception.Message)"; return }
        while (-not $sync.Stop) {
            try {
                $sync.Status = @{
                    Models  = @(Get-LlmStatus)
                    Ollama  = Get-OllamaStatus
                    Gpu     = Get-GpuMemory
                    At      = (Get-Date).ToString('HH:mm:ss')
                }
                $sync.WorkerError = $null
            } catch {
                $sync.WorkerError = $_.Exception.Message
            }

            $cmd = $sync.Cmd
            if ($cmd) {
                $sync.Cmd = $null
                $parts = $cmd -split '\|'
                $r = $null
                try {
                    switch ($parts[0]) {
                        'start'  { $r = Start-LlmModel -Key $parts[1] -CtxOverride ([int]$parts[2]) }
                        'stop'   { $r = Stop-LlmModel }
                        'unload' { $r = Stop-OllamaModel }
                        'ostart' { $r = Start-Ollama }
                        'ostop'  { $r = Stop-Ollama }
                    }
                } catch { $r = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message; Detail = '' } }
                if ($r) { $sync.Res = @{ Ok = $r.Ok; Message = $r.Message } }
            }
            Start-Sleep -Milliseconds $intervalMs
        }
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $pwsh = [powershell]::Create()
    $pwsh.Runspace = $rs
    [void]$pwsh.AddScript($worker).AddArgument($sync).AddArgument($corePath).AddArgument(1500)
    [void]$pwsh.BeginInvoke()

    # ---------------------------------------------------------------- 窗体

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = '本地模型控制台'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false
    $form.StartPosition   = 'CenterScreen'
    $form.BackColor       = $C.Bg
    $form.ClientSize      = New-Object System.Drawing.Size((S 660), (S 520))
    $form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $script:Form = $form

    # 双缓冲：否则每次重绘会先擦背景，造成整窗闪烁
    try {
        $flags   = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $styleMi = [System.Windows.Forms.Control].GetMethod('SetStyle', $flags)
        $styles  = [System.Windows.Forms.ControlStyles]'AllPaintingInWmPaint, OptimizedDoubleBuffer, UserPaint'
        [void]$styleMi.Invoke($form, @($styles, $true))
        $dbProp  = [System.Windows.Forms.Form].GetProperty('DoubleBuffered', $flags)
        $dbProp.SetValue($form, $true, $null)
    } catch { }

    $fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $fCard  = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $fSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)

    function Add-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $color, $font, [string]$align = 'MiddleLeft') {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h)
        if ($color) { $l.ForeColor = $color }
        if ($font)  { $l.Font = $font }
        $l.TextAlign = $align
        $l.BackColor = [System.Drawing.Color]::Transparent
        $form.Controls.Add($l)
        return $l
    }

    function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [string]$tag) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Tag = $tag
        $b.Location = New-Object System.Drawing.Point($x, $y)
        $b.Size = New-Object System.Drawing.Size($w, (S 28))
        $form.Controls.Add($b)
        return $b
    }

    $null = Add-Label '本地模型控制台' (S 18) (S 12) (S 240) (S 30) $C.Text $fTitle
    $null = Add-Label '显存' (S 18) (S 62) (S 40) (S 22) $C.Sub $null
    $lblGpu  = Add-Label '— / — GB' (S 378) (S 62) (S 120) (S 22) $C.Text $null
    $lblFree = Add-Label '' (S 496) (S 62) (S 100) (S 22) $C.Sub $null

    $btnRefresh = New-Btn '刷新' (S 560) (S 16) (S 82) 'refresh'

    $llamaModels = @($Models.Keys | Sort-Object { $Models[$_].Port } |
                     ForEach-Object { $Models[$_] } | Where-Object { $_.Kind -eq 'llama' })
    $ollamaModel = @($Models.Keys | ForEach-Object { $Models[$_] } |
                     Where-Object { $_.Kind -eq 'ollama' } | Select-Object -First 1)

    $top = 108
    foreach ($m in $llamaModels) {
        $y = S $top
        $null = Add-Label $m.Name (S 42) ($y + (S 14)) (S 240) (S 26) $C.Text $fCard
        $lblState = Add-Label '已停止' (S 388) ($y + (S 14)) (S 132) (S 26) $C.Gray $null 'MiddleRight'
        $lblPid   = Add-Label '' (S 528) ($y + (S 14)) (S 108) (S 26) $C.Sub $fSmall 'MiddleRight'
        $null = Add-Label (":$($m.Port)") (S 42) ($y + (S 48)) (S 80) (S 22) $C.Sub $fSmall
        $null = Add-Label '上下文' (S 128) ($y + (S 48)) (S 46) (S 22) $C.Sub $fSmall

        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'
        $cb.Location = New-Object System.Drawing.Point((S 176), ($y + (S 42)))
        $cb.Size = New-Object System.Drawing.Size((S 88), (S 26))
        # 档位来自 models.json 的 tiers（含每档适用场景）
        $tiers = @($m.Tiers)
        if ($tiers.Count -eq 0) { $tiers = @([pscustomobject]@{ ctx = [int]$m.Ctx; vram = [int]$m.Vram; use = '' }) }
        $opts = @($tiers | ForEach-Object { [int]$_.ctx })
        foreach ($tr in $tiers) { [void]$cb.Items.Add("$([math]::Round([double]$tr.ctx / 1024))K") }
        $idx = [array]::IndexOf([object[]]$opts, [int]$m.Ctx)
        $cb.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
        $cb.Tag = $m.Key
        $cb.add_SelectedIndexChanged({
            param($sender, $e)
            try {
                if ($null -eq $script:LblMsg) { return }
                $tag = [string]$sender.Tag
                $c = $script:CardRefs[$tag]
                if ($null -eq $c) { return }
                $ts = @($c.Tiers)
                $si = [int]$sender.SelectedIndex
                if ($si -lt 0 -or $si -ge $ts.Count) { return }
                $script:LblMsg.Text = [string]$ts[$si].use
                $script:LblMsg.ForeColor = if ([double]$ts[$si].ctx -ge 163840) { $script:C.Yellow } else { $script:C.Sub }
            } catch { }
        })
        $form.Controls.Add($cb)

        $lblVram = Add-Label '显存 —' (S 280) ($y + (S 48)) (S 140) (S 22) $C.Sub $fSmall
        $btn     = New-Btn '启动' (S 432) ($y + (S 62)) (S 88)  $m.Key
        $btnLog  = New-Btn '日志' (S 528) ($y + (S 62)) (S 108) $m.Key

        $script:CardRefs[$m.Key] = @{
            Key = $m.Key; Kind = 'llama'; Model = $m; Top = $top
            State = $lblState; Pid = $lblPid; Vram = $lblVram
            Ctx = $cb; CtxOpts = @($opts); Tiers = @($tiers); Btn = $btn; Log = $btnLog
        }
        $top += 108
    }

    if ($ollamaModel) {
        $y = S $top
        $null = Add-Label $ollamaModel.Name (S 42) ($y + (S 14)) (S 240) (S 26) $C.Text $fCard
        $lblOState = Add-Label '未运行' (S 388) ($y + (S 14)) (S 132) (S 26) $C.Gray $null 'MiddleRight'
        $null = Add-Label ':11434' (S 42) ($y + (S 48)) (S 80) (S 22) $C.Sub $fSmall
        $lblOVram  = Add-Label '—' (S 128) ($y + (S 48)) (S 180) (S 22) $C.Sub $fSmall

        $btnOStart = New-Btn '启动'     (S 336) ($y + (S 62)) (S 88)  $ollamaModel.Key
        $btnUnload = New-Btn '卸载模型' (S 432) ($y + (S 62)) (S 88)  $ollamaModel.Key
        $btnOLog   = New-Btn '日志'     (S 528) ($y + (S 62)) (S 108) $ollamaModel.Key

        $script:CardRefs[$ollamaModel.Key] = @{
            Key = $ollamaModel.Key; Kind = 'ollama'; Model = $ollamaModel; Top = $top
            State = $lblOState; Vram = $lblOVram; Btn = $btnOStart; Unload = $btnUnload; Log = $btnOLog
        }
        $top += 108
    }

    $lblAt   = Add-Label '等待后台…' (S 18) (S 448) (S 200) (S 22) $C.Sub $fSmall
    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = '自动刷新'; $chkAuto.Checked = $true
    $chkAuto.Location = New-Object System.Drawing.Point((S 226), (S 445))
    $chkAuto.Size = New-Object System.Drawing.Size((S 96), (S 24))
    $form.Controls.Add($chkAuto)
    $lblMsg  = Add-Label '' (S 330) (S 448) (S 180) (S 22) $C.Sub $fSmall 'MiddleRight'
    $lblIdle = Add-Label '○ 空闲' (S 516) (S 448) (S 124) (S 22) $C.Sub $fSmall 'MiddleRight'
    $script:LblMsg = $lblMsg

    # ---------------------------------------------------------------- 绘制

    function Get-RoundPath([System.Drawing.RectangleF]$r, [float]$rad) {
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $rad * 2
        $gp.AddArc($r.X, $r.Y, $d, $d, 180, 90)
        $gp.AddArc(($r.Right - $d), $r.Y, $d, $d, 270, 90)
        $gp.AddArc(($r.Right - $d), ($r.Bottom - $d), $d, $d, 0, 90)
        $gp.AddArc($r.X, ($r.Bottom - $d), $d, $d, 90, 90)
        $gp.CloseFigure()
        return $gp
    }

    $form.add_Paint({
        param($sender, $e)
        try {
            $gr = $e.Graphics
            $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

            $penLine = New-Object System.Drawing.Pen($script:C.Border, 1)
            $gr.DrawLine($penLine, 0, (S 52), $sender.Width, (S 52))
            $gr.DrawLine($penLine, 0, (S 436), $sender.Width, (S 436))

            $bw = S 300; $bh = S 16; $bx = S 64; $by = S 64
            $rect = New-Object System.Drawing.RectangleF($bx, $by, $bw, $bh)
            $path = Get-RoundPath $rect ([float](S 8))
            $br = New-Object System.Drawing.SolidBrush($script:C.BarBg)
            $gr.FillPath($br, $path)
            if ($script:Gpu.Total -gt 0 -and $script:Gpu.Used -gt 0) {
                $ratio = [math]::Min(1.0, $script:Gpu.Used / $script:Gpu.Total)
                $fw = [math]::Max([double](S 8), $bw * $ratio)
                $rf = New-Object System.Drawing.RectangleF($bx, $by, [float]$fw, $bh)
                $pf = Get-RoundPath $rf ([float](S 8))
                $bf = New-Object System.Drawing.SolidBrush($script:C.Blue)
                $gr.FillPath($bf, $pf)
                $bf.Dispose(); $pf.Dispose()
            }
            $br.Dispose(); $path.Dispose()

            foreach ($kk in @($script:CardRefs.Keys)) {
                $card = $script:CardRefs[$kk]
                $r = New-Object System.Drawing.RectangleF((S 16), (S $card.Top), (S 628), (S 96))
                $p = Get-RoundPath $r ([float](S 10))
                $b = New-Object System.Drawing.SolidBrush($script:C.Card)
                $gr.FillPath($b, $p)
                $pen = New-Object System.Drawing.Pen($script:C.Border, 1)
                $gr.DrawPath($pen, $p)

                $state = 'stopped'
                if ($card.Kind -eq 'ollama') {
                    if ($script:OllamaOk) { $state = 'running' }
                } else {
                    foreach ($v in $script:View) { if ($v.Key -eq $kk) { $state = $v.State; break } }
                }

                $dc = switch ($state) { 'running' { $script:C.Green } 'starting' { $script:C.Yellow } default { $script:C.Gray } }
                $ds = S 12; $dx = S 24; $dy = $r.Y + (S 21)
                if ($state -eq 'stopped') {
                    $pd = New-Object System.Drawing.Pen($dc, [float](S 1.5))
                    $gr.DrawEllipse($pd, $dx, $dy, $ds, $ds)
                    $pd.Dispose()
                } else {
                    $bd = New-Object System.Drawing.SolidBrush($dc)
                    $gr.FillEllipse($bd, $dx, $dy, $ds, $ds)
                    $bd.Dispose()
                }
                $b.Dispose(); $pen.Dispose(); $p.Dispose()
            }
            $penLine.Dispose()
        } catch {
            Write-GuiError 'paint' $_
        }
    })

    # ---------------------------------------------------------------- 刷新

    function Update-Ui {
        try {
            $st = $sync.Status
            if ($null -eq $st) { return }
            if ($sync.WorkerError) { $lblMsg.Text = '错误: ' + $sync.WorkerError; return }

            $script:Gpu = @{ Used = [double]$st.Gpu.Used; Total = [double]$st.Gpu.Total }
            $lblGpu.Text  = "{0:N1} / {1:N1} GB" -f ($st.Gpu.Used / 1024), ($st.Gpu.Total / 1024)
            $lblFree.Text = "余 {0:N1} GB" -f ($st.Gpu.Free / 1024)
            $lblAt.Text   = "上次刷新 " + $st.At
            $script:OllamaOk = [bool]$st.Ollama.ApiOk

            $view = @()
            foreach ($mm in @($st.Models)) { $view += [pscustomobject]@{ Key = $mm.Key; State = $mm.State } }
            $script:View = $view

            foreach ($kk in @($script:CardRefs.Keys)) {
                $card = $script:CardRefs[$kk]
                if ($card.Kind -eq 'llama') {
                    $s = $null
                    foreach ($mm in @($st.Models)) { if ($mm.Key -eq $kk) { $s = $mm; break } }
                    if ($null -eq $s) { continue }

                    $isBusy   = ($script:BusyKey -eq $kk)
                    $stateNow = if ($isBusy) { 'starting' } else { $s.State }

                    switch ($stateNow) {
                        'running'  { $card.State.Text = '运行中';   $card.State.ForeColor = $script:C.Green }
                        'starting' { $card.State.Text = '启动中…'; $card.State.ForeColor = $script:C.Yellow }
                        default    { $card.State.Text = '已停止';   $card.State.ForeColor = $script:C.Gray }
                    }
                    if ($s.Note) { $card.State.Text = $s.Note; $card.State.ForeColor = $script:C.Yellow }

                    $card.Pid.Text  = if ($s.Pid) { "pid $($s.Pid)" } else { '' }
                    $card.Vram.Text = if ($s.State -eq 'running') { '显存 {0:N1} GB' -f ($s.VramEst / 1024) } else { '显存 —' }
                    $card.Ctx.Enabled = (($s.State -eq 'stopped') -and (-not $isBusy))
                    $card.Btn.Enabled = ($stateNow -ne 'starting')
                    $card.Btn.Text = if ($s.State -eq 'running') { '停止' } elseif ($stateNow -eq 'starting') { '启动中…' } else { '启动' }
                } else {
                    $ol = $st.Ollama
                    $isBusy = ($script:BusyKey -eq 'ollama')
                    $card.State.Text = if ($ol.ApiOk) { '服务在线' } else { '未运行' }
                    $card.State.ForeColor = if ($ol.ApiOk) { $script:C.Green } else { $script:C.Gray }
                    $card.Vram.Text = if (@($ol.Loaded).Count -gt 0) { '已加载 {0:N1} GB' -f ($ol.Loaded[0].VramMiB / 1024) } else { '—' }
                    $card.Btn.Enabled    = ((-not $ol.ApiOk) -and (-not $isBusy))
                    $card.Unload.Enabled = ((@($ol.Loaded).Count -gt 0) -and (-not $isBusy))
                }
            }

            $lblIdle.Text = if ($script:BusyKey) { '● 执行中' } else { '○ 空闲' }

            $res = $sync.Res
            if ($null -ne $res) {
                $sync.Res = $null
                $script:BusyKey = $null
                $lblMsg.Text = [string]$res.Message
            }

            # 只在数据变化时重绘
            $pk = "{0}|{1}|{2}" -f $st.At, $script:OllamaOk, $script:BusyKey
            if ($pk -ne $script:LastKey) {
                $script:LastKey = $pk
                $form.Invalidate()
            }
        } catch {
            Write-GuiError 'update' $_
        }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.add_Tick({ Update-Ui })
    $timer.Start()

    # ---------------------------------------------------------------- 交互（不做闭包）

    $btnRefresh.add_Click({
        param($sender, $e)
        try { $script:Form.Invalidate() } catch { Write-GuiError 'refresh' $_ }
    })

    foreach ($kk in @($script:CardRefs.Keys)) {
        $card = $script:CardRefs[$kk]
        if ($card.Kind -eq 'llama') {
            $card.Btn.add_Click({
                param($sender, $e)
                try {
                    if ($script:BusyKey) { return }
                    $target = [string]$sender.Tag
                    $s = $null
                    if ($script:Sync.Status) {
                        foreach ($mm in @($script:Sync.Status.Models)) { if ($mm.Key -eq $target) { $s = $mm; break } }
                    }
                    if ($s -and $s.State -eq 'running') {
                        $script:BusyKey = $target
                        $script:Sync.Cmd = 'stop'
                    } else {
                        $c = $script:CardRefs[$target]
                        $i = $c.Ctx.SelectedIndex
                        $ctx = if ($i -ge 0 -and $i -lt $c.CtxOpts.Count) { [int]$c.CtxOpts[$i] } else { [int]$c.Model.Ctx }
                        $script:BusyKey = $target
                        $script:Sync.Cmd = "start|$target|$ctx"
                    }
                    $script:LblMsg.Text = '执行中…'
                    $script:Form.Invalidate()
                } catch { Write-GuiError 'click-start' $_ }
            })
        } else {
            $card.Btn.add_Click({
                param($sender, $e)
                try {
                    if (-not $script:BusyKey) {
                        $script:BusyKey = 'ollama'
                        $script:Sync.Cmd = 'ostart'
                        $script:LblMsg.Text = '启动 Ollama…'
                    }
                } catch { Write-GuiError 'click-ostart' $_ }
            })
            $card.Unload.add_Click({
                param($sender, $e)
                try {
                    if (-not $script:BusyKey) {
                        $script:BusyKey = 'ollama'
                        $script:Sync.Cmd = 'unload'
                        $script:LblMsg.Text = '卸载中…'
                    }
                } catch { Write-GuiError 'click-unload' $_ }
            })
        }

        $card.Log.add_Click({
            param($sender, $e)
            try {
                $target = [string]$sender.Tag
                $lp = Join-Path $LogDir "serve-$target.err.log"
                if (-not (Test-Path -LiteralPath $lp)) { $lp = Join-Path $LogDir "serve-$target.out.log" }
                if (Test-Path -LiteralPath $lp) { Start-Process notepad.exe $lp }
                else { [void][System.Windows.Forms.MessageBox]::Show("没有找到 $target 的日志", '提示') }
            } catch { Write-GuiError 'click-log' $_ }
        })
    }

    $form.add_FormClosing({
        param($sender, $e)
        if ($script:SelfTestMode) { return }
        if ($script:Closing) { return }
        try {
            $running = @()
            if ($sync.Status) {
                foreach ($mm in @($sync.Status.Models)) { if ($mm.State -eq 'running' -or $mm.State -eq 'starting') { $running += $mm } }
            }
            if ($running.Count -eq 0) { return }
            $r = [System.Windows.Forms.MessageBox]::Show(
                "$($running[0].Name) 仍在运行，显存未释放。`n`n是：停止服务并退出`n否：保持运行并退出`n取消：返回",
                '确认退出', 'YesNoCancel', 'Question')
            if ($r -eq 'Cancel') { $e.Cancel = $true; return }
            if ($r -eq 'Yes') { $sync.Cmd = 'stop'; Start-Sleep -Seconds 3 }
            $script:Closing = $true
        } catch { Write-GuiError 'closing' $_ }
    })

    # ---------------------------------------------------------------- 运行

    $form.Show()

    if ($SelfTest) {
        for ($i = 0; $i -lt 24; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250 }

        $clickResult = 'skipped'
        if ($ClickTest) {
            $card9 = $script:CardRefs['9b']
            if ($card9) {
                # 第一次点击：启动
                $card9.Btn.PerformClick()
                for ($i = 0; $i -lt 80; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250 }
                $s1 = 'n/a'
                if ($sync.Status) { foreach ($mm in @($sync.Status.Models)) { if ($mm.Key -eq '9b') { $s1 = $mm.State; break } } }

                # 第二次点击：应当是「停止」
                $card9.Btn.PerformClick()
                for ($i = 0; $i -lt 40; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250 }
                $s2 = 'n/a'
                if ($sync.Status) { foreach ($mm in @($sync.Status.Models)) { if ($mm.Key -eq '9b') { $s2 = $mm.State; break } } }

                $clickResult = "start=$s1 stop=$s2"
                $sync.Cmd = 'stop'
                for ($i = 0; $i -lt 8; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250 }
            } else { $clickResult = 'no-card' }
        }
        $png = Join-Path $PSScriptRoot 'gui-live-selftest.png'
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()

        $timer.Stop()
        $form.Hide()
        $sync.Stop = $true
        Start-Sleep -Milliseconds 300
        try { $pwsh.Stop() } catch { }
        try { $rs.Close() } catch { }
        $form.Dispose()
        Set-Content -LiteralPath (Join-Path $PSScriptRoot "logs\gui-selftest.txt") -Value "click=$clickResult png=$png" -Encoding UTF8
        Write-Output "SELFTEST click=$clickResult png=$png"
        return 0
    }

    [System.Windows.Forms.Application]::Run($form)

    $timer.Stop()
    $sync.Stop = $true
    Start-Sleep -Milliseconds 300
    try { $pwsh.Stop() } catch { }
    try { $rs.Close() } catch { }
    return 0
}


