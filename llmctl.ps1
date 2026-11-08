#requires -Version 7.0
<#
  llmctl.ps1 — 本地模型统一控制台（方案 A：分层 + 控制台优先）

  设计约束：
    * 核心函数（Get-LlmStatus / Start-LlmModel / Stop-LlmModel / Ollama 三件套）
      一律返回对象，**不产生任何输出**，便于将来被 GUI 复用。
    * 渲染只发生在 CLI 层（Write-* 只出现在 Render-* 与菜单里）。

  用法：
    .\llmctl.ps1                      # 交互菜单
    .\llmctl.ps1 status               # 状态表
    .\llmctl.ps1 start 9b [-Ctx N]    # 启动
    .\llmctl.ps1 stop [-All]          # 停止 llama（-All 连 Ollama 一起停）
    .\llmctl.ps1 log 9b               # 打开日志
    .\llmctl.ps1 ollama start|unload|stop|status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string] $Command,
    [Parameter(Position = 1)][string] $Target,
    [int]    $Ctx,
    [switch] $All,
    [switch] $SelfTest,
    [switch] $ClickTest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 配置

# 加载核心层（配置 + 全部核心函数）
. (Join-Path $PSScriptRoot 'llmctl-core.ps1')

# ---------------------------------------------------------------- CLI 渲染层

function Get-StateGlyph {
    param($State)
    switch ($State) {
        'running'  { @{ Text = '●'; Color = 'Green' } }
        'starting' { @{ Text = '◐'; Color = 'Yellow' } }
        default    { @{ Text = '○'; Color = 'DarkGray' } }
    }
}

function Render-Status {
    $gpu = Get-GpuMemory
    $llm = @(Get-LlmStatus)
    $ol  = Get-OllamaStatus

    Write-Host ''
    if ($gpu.Ok) {
        Write-Host ("  本地模型控制台" + (" " * 12) + "显存 {0} / {1} MiB (余 {2})" -f $gpu.Used, $gpu.Total, $gpu.Free) -ForegroundColor Cyan
    } else {
        Write-Host "  本地模型控制台" -ForegroundColor Cyan
    }
    Write-Host ''

    $i = 1
    foreach ($s in $llm) {
        $g = Get-StateGlyph $s.State
        $stateText = switch ($s.State) { 'running' { '运行中' } 'starting' { '启动中' } default { '已停止' } }
        $pidText = if ($s.Pid) { "pid $($s.Pid)" } else { '—' }
        $vramText = if ($s.State -eq 'running') { "$([math]::Round($s.VramEst/1024,1)) GB*" } else { '—' }
        Write-Host ("  [{0}] {1,-16} " -f $i, $s.Name) -NoNewline
        Write-Host ("{0} {1,-6} " -f $g.Text, $stateText) -NoNewline -ForegroundColor $g.Color
        Write-Host ("{0,-12} :{1,-6} {2,-6} {3}" -f $pidText, $s.Port, "$([math]::Round($s.Ctx/1024))K", $vramText) -NoNewline
        if ($s.Note) { Write-Host ("  " + $s.Note) -NoNewline -ForegroundColor DarkYellow }
        Write-Host ''
        $i++
    }

    $g2 = if ($ol.ApiOk) { @{ Text = '●'; Color = 'Green' } } else { @{ Text = '○'; Color = 'DarkGray' } }
    $olState = if ($ol.ApiOk) { '服务在线' } else { '未运行' }
    $loadedText = if ($ol.Loaded.Count) { ($ol.Loaded | ForEach-Object { "$($_.Name) $([math]::Round($_.VramMiB/1024,1))GB" }) -join ', ' } else { '—' }
    Write-Host ("  [{0}] {1,-16} " -f $i, 'qwen3 (Ollama)') -NoNewline
    Write-Host ("{0} {1,-6} " -f $g2.Text, $olState) -NoNewline -ForegroundColor $g2.Color
    $olCtx = if ($Models.ContainsKey('qwen3')) { "$([math]::Round($Models['qwen3'].Ctx/1024))K" } else { '—' }
    Write-Host ("{0,-12} :{1,-6} {2,-6} {3}" -f '—', $ol.Port, $olCtx, $loadedText)
    Write-Host ''
    Write-Host '  * 显存为预估峰值' -ForegroundColor DarkGray
    Write-Host ''
}

function Render-Help {
    Write-Host '  1-3 启动/切换   s 停止   o 卸载Ollama模型   l 日志   r 刷新   q 退出' -ForegroundColor DarkGray
}

function Get-LogPath {
    param([string]$Key)
    $p = Join-Path $LogDir "serve-$Key.out.log"
    if (Test-Path -LiteralPath $p) { return $p }
    $p2 = Join-Path $LogDir "serve-$Key.err.log"
    if (Test-Path -LiteralPath $p2) { return $p2 }
    $null
}

# ---------------------------------------------------------------- 交互菜单

function Start-Menu {
    while ($true) {
        Render-Status
        Render-Help
        Write-Host '  > ' -NoNewline
        $inp = Read-Host
        if ([string]::IsNullOrWhiteSpace($inp)) { continue }
        $inp = $inp.Trim().ToLower()

        switch ($inp) {
            '1' { Invoke-Start '9b' }
            '2' { Invoke-Start '27b' }
            '3' { $r = Start-Ollama; Write-Host ("  " + $r.Message) -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}); Start-Sleep 1 }
            's' {
                $r = Stop-LlmModel
                Write-Host ("  " + $r.Message) -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                Start-Sleep 1
            }
            'o' {
                $r = Stop-OllamaModel
                Write-Host ("  " + $r.Message) -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                Start-Sleep 1
            }
            'l' {
                foreach ($k in ($Models.Keys | Sort-Object)) {
                    $p = Get-LogPath $k
                    if ($p) { Write-Host ("  $k : $p") ; Start-Process notepad.exe $p }
                }
                Start-Sleep 1
            }
            'r' { continue }
            'q' {
                $running = @(Get-LlmServerProcess)
                if ($running.Count -gt 0) {
                    Write-Host "  仍有 llama-server 在运行（显存未释放），确认退出？(y/N) " -NoNewline -ForegroundColor Yellow
                    $a = Read-Host
                    if ($a -notmatch '^y') { continue }
                }
                return 0
            }
            default { Write-Host '  无效输入' -ForegroundColor DarkYellow; Start-Sleep -Milliseconds 600 }
        }
    }
}

function Invoke-Start {
    param([string]$Key)
    $running = @(Get-LlamaServerProcess)
    if ($running.Count -gt 0) {
        $cur = Resolve-ModelByPath $running[0].ModelPath
        if ($cur -and $cur.Key -ne $Key) {
            Write-Host "  $($cur.Name) 正在运行，是否切换？(y/N) " -NoNewline -ForegroundColor Yellow
            if ((Read-Host) -notmatch '^y') { return }
            $null = Stop-LlmModel
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Host "  启动中… " -NoNewline -ForegroundColor Cyan
    $r = Start-LlmModel -Key $Key
    if ($r.Ok) { Write-Host $r.Message -ForegroundColor Green }
    else {
        Write-Host $r.Message -ForegroundColor Red
        if ($r.Detail) { $r.Detail -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    }
    Start-Sleep 1
}

# ---------------------------------------------------------------- 命令分发

function Invoke-Cli {
    switch ($Command.ToLower()) {
        'status' {
            Render-Status
            return 0
        }
        'start' {
            if (-not $Target) { Write-Host '用法: .\llmctl.ps1 start <9b|27b>' -ForegroundColor Red; return 1 }
            $r = Start-LlmModel -Key $Target.ToLower() -CtxOverride $Ctx
            Write-Host $r.Message -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' })
            if ($r.Detail) { $r.Detail -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
            return $r.Code
        }
        'stop' {
            $r = Stop-LlmModel
            Write-Host $r.Message -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' })
            $code = $r.Code
            if ($All) {
                $o = Stop-Ollama
                Write-Host $o.Message -ForegroundColor Green
            }
            return $code
        }
        'tiers' {
            $key = if ($Target) { $Target.ToLower() } else { '9b' }
            if (-not $Models.ContainsKey($key)) { Write-Host "未知模型: $key" -ForegroundColor Red; return 1 }
            $m = $Models[$key]
            Write-Host ''
            Write-Host ("  {0}  ({1})" -f $m.Name, (Split-Path $m.File -Leaf)) -ForegroundColor Cyan
            Write-Host ("  {0,-8} {1,10}   {2}" -f '上下文', '显存估算', '适合做什么') -ForegroundColor DarkGray
            foreach ($tr in @($m.Tiers)) {
                if ($null -eq $tr) { continue }
                Write-Host ("  {0,-8} {1,8:N0} MiB   {2}" -f "$([math]::Round([double]$tr.ctx / 1024))K", [double]$tr.vram, [string]$tr.use)
            }
            Write-Host ''
            return 0
        }
        'log' {
            if (-not $Target) { Write-Host '用法: .\llmctl.ps1 log <9b|27b>' -ForegroundColor Red; return 1 }
            $p = Get-LogPath $Target.ToLower()
            if (-not $p) { Write-Host "没有找到 $Target 的日志" -ForegroundColor Red; return 4 }
            Start-Process notepad.exe $p
            return 0
        }
        'ollama' {
            switch (($Target + '').ToLower()) {
                'start'  { $r = Start-Ollama;      Write-Host $r.Message -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}); return $r.Code }
                'unload' { $r = Stop-OllamaModel;  Write-Host $r.Message -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}); return $r.Code }
                'stop'   { $r = Stop-Ollama;       Write-Host $r.Message -ForegroundColor Green; return 0 }
                'status' {
                    $st = Get-OllamaStatus
                    Write-Host "  托盘应用 : $(if($st.AppRunning){"运行 pid $($st.AppPid)"}else{'未运行'})"
                    Write-Host "  服务进程 : $(if($st.ServerRunning){"运行 pid $($st.ServerPid)"}else{'未运行'})"
                    Write-Host "  API      : $(if($st.ApiOk){'可达'}else{'不可达'})"
                    Write-Host "  已安装   : $($st.Installed -join ', ')"
                    Write-Host "  已加载   : $(if($st.Loaded.Count){($st.Loaded | ForEach-Object {"$($_.Name) $($_.VramMiB)MiB"}) -join ', '}else{'无'})"
                    return 0
                }
                default { Write-Host '用法: .\llmctl.ps1 ollama start|unload|stop|status' -ForegroundColor Red; return 1 }
            }
        }
        default {
            Write-Host "未知命令: $Command" -ForegroundColor Red
            Write-Host '可用: status | start | stop | log | ollama'
            return 1
        }
    }
}

# ---------------------------------------------------------------- 入口

if ($Command -eq 'gui') {
    . (Join-Path $PSScriptRoot 'llmctl-gui.ps1')
    exit (Start-LlmGui -SelfTest:$SelfTest -ClickTest:$ClickTest)
}

if (-not $Command) {
    exit (Start-Menu)
} else {
    exit (Invoke-Cli)
}


