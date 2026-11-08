#requires -Version 7.0
<#
  llmctl-core.ps1 — 核心层（只放函数与配置，无入口、无输出）

  被 llmctl.ps1（CLI/菜单）与 llmctl-gui.ps1（图形界面）、
  以及后台 runspace 共同 dot-source。任何 Write-* 都不应出现在这里。
#>

$RootDir = $PSScriptRoot
$ConfigPath = Join-Path $RootDir 'models.json'

$DefaultConfig = [ordered]@{
    app       = Join-Path $RootDir 'app'
    logDir    = Join-Path $RootDir 'logs'
    ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    models    = @(
        [ordered]@{ key='9b';   kind='llama';  name='Bonsai 2 9B';  file=(Join-Path $RootDir 'models\Ternary-Bonsai-2-9B-PQ2_0.gguf');  alias='bonsai-2-9b';  port=8080;  ctx=32768; maxCtx=65536; vram=3424 }
        [ordered]@{ key='27b';  kind='llama';  name='Bonsai 2 27B'; file=(Join-Path $RootDir 'models\Ternary-Bonsai-2-27B-PTQ1_0.gguf'); alias='bonsai-2-27b'; port=8081;  ctx=16384; maxCtx=32768; vram=6854 }
        [ordered]@{ key='qwen3';kind='ollama'; name='qwen3:8b-16k';  file='qwen3:8b-16k';                                            alias='';             port=11434; ctx=16384; maxCtx=16384; vram=6112 }
    )
}

$Config = if (Test-Path -LiteralPath $ConfigPath) {
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $DefaultConfig }

# 解析配置里的路径：支持 .\ 相对路径（相对于脚本目录）与 %ENV% 环境变量展开
function Resolve-CfgPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $p = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ($p -match '^[\.~]' -or -not [System.IO.Path]::IsPathRooted($p)) {
        $p = Join-Path $RootDir $p
    }
    return [System.IO.Path]::GetFullPath($p)
}

# 统一成可直接点取的对象数组
$Models = @{}
foreach ($m in $Config.models) {
    $Models[$m.key] = [pscustomobject]@{
        Key = $m.key; Kind = $m.kind; Name = $m.name
        File = if ($m.kind -eq 'ollama') { $m.file } else { Resolve-CfgPath $m.file }
        Alias = $m.alias; Port = [int]$m.port; Ctx = [int]$m.ctx
        MaxCtx = [int]$m.maxCtx; Vram = [int]$m.vram
        Tiers = @($m.tiers)
    }
}
$AppDir    = Resolve-CfgPath $Config.app
$LogDir    = Resolve-CfgPath $Config.logDir
$OllamaExe = Resolve-CfgPath $Config.ollamaExe
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
# ---------------------------------------------------------------- 核心：系统探针

function Get-GpuMemory {
    $raw = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return [pscustomobject]@{ Used = -1; Total = -1; Free = -1; Ok = $false } }
    $parts = ($raw -split ',')
    $used = [int]($parts[0] -replace '[^0-9]', '')
    $tot  = [int]($parts[1] -replace '[^0-9]', '')
    [pscustomobject]@{ Used = $used; Total = $tot; Free = ($tot - $used); Ok = $true }
}

function Test-PortBusy {
    param([int]$Port)
    [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Get-LlamaServerProcess {
    Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $cmd = $_.CommandLine
            $modelPath = $null; $port = $null; $ctx = $null
            if ($cmd -match '-m\s+"([^"]+)"')      { $modelPath = $Matches[1] }
            elseif ($cmd -match '-m\s+(\S+)')      { $modelPath = $Matches[1] }
            if ($cmd -match '--port\s+(\d+)')      { $port = [int]$Matches[1] }
            if ($cmd -match '(?:^|\s)-c\s+(\d+)')  { $ctx  = [int]$Matches[1] }
            [pscustomobject]@{ Pid = $_.ProcessId; ModelPath = $modelPath; Port = $port; Ctx = $ctx; CommandLine = $cmd }
        }
}

function Resolve-ModelByPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $leaf = Split-Path -Leaf $Path
    foreach ($k in $Models.Keys) {
        if ([System.IO.Path]::GetFileName($Models[$k].File) -eq $leaf) { return $Models[$k] }
    }
    $null
}

function Test-Endpoint {
    param([int]$Port)
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 2; $true }
    catch { $false }
}

# ---------------------------------------------------------------- 核心：llama.cpp

function Get-LlmStatus {
    $gpu = Get-GpuMemory
    $procs = @(Get-LlamaServerProcess)
    $first = $procs | Select-Object -First 1
    $runningModel = if ($first) { Resolve-ModelByPath $first.ModelPath } else { $null }

    $out = foreach ($k in ($Models.Keys | Sort-Object { $Models[$_].Port })) {
        $m = $Models[$k]
        if ($m.Kind -ne 'llama') { continue }

        $state = 'stopped'; $pid_ = $null; $ready = $false; $note = ''; $ctxShow = $m.Ctx
        if ($runningModel -and $runningModel.Key -eq $k) {
            $state = 'running'; $pid_ = $first.Pid
            $ready = Test-Endpoint $(if ($first.Port) { $first.Port } else { $m.Port })
            if (-not $ready) { $state = 'starting' }
            if ($first.Ctx) { $ctxShow = $first.Ctx }
        } elseif ($runningModel) {
            $note = "被 $($runningModel.Name) 占用"
        }

        [pscustomobject]@{
            Key = $k; Name = $m.Name; Kind = 'llama'; State = $state; Pid = $pid_
            Port = $m.Port; Ctx = $ctxShow; Ready = $ready; VramEst = $m.Vram
            ModelFile = $m.File; Note = $note
            GpuUsed = $gpu.Used; GpuTotal = $gpu.Total
        }
    }
    $out
}

function Start-LlmModel {
    param([string]$Key, [int]$CtxOverride = 0)

    if (-not $Models.ContainsKey($Key)) { return [pscustomobject]@{ Ok=$false; Code=1; Message="未知模型: $Key"; Pid=$null } }
    $m = $Models[$Key]
    if ($m.Kind -ne 'llama') { return [pscustomobject]@{ Ok=$false; Code=1; Message="$($m.Name) 不是 llama 模型"; Pid=$null } }

    if (-not (Test-Path -LiteralPath $m.File)) {
        return [pscustomobject]@{ Ok=$false; Code=4; Message="模型文件缺失: $($m.File)"; Pid=$null }
    }
    $exe = Join-Path $AppDir 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ Ok=$false; Code=4; Message="找不到 llama-server.exe: $AppDir"; Pid=$null }
    }

    $running = @(Get-LlamaServerProcess)
    if ($running.Count -gt 0) {
        $cur = Resolve-ModelByPath $running[0].ModelPath
        if ($cur -and $cur.Key -eq $Key) {
            return [pscustomobject]@{ Ok=$true; Code=0; Message="$($m.Name) 已在运行 (pid $($running[0].Pid))"; Pid=$running[0].Pid }
        }
        $msg = if ($cur) { "已有 $($cur.Name) 在运行，请先停止" } else { "已有 llama-server 在运行 (pid $($running[0].Pid))，请先停止" }
        return [pscustomobject]@{ Ok=$false; Code=5; Message=$msg; Pid=$null }
    }

    if (Test-PortBusy $m.Port) {
        return [pscustomobject]@{ Ok=$false; Code=2; Message="端口 $($m.Port) 已被其他程序占用"; Pid=$null }
    }

    $ctx = if ($CtxOverride -gt 0) { $CtxOverride } else { $m.Ctx }
    if ($ctx -gt $m.MaxCtx) { $ctx = $m.MaxCtx }

    # 注意：必须用双引号插值。PowerShell 中 -f 优先级高于 +，'a'+'b' -f x 只会格式化最后一段。
    $argLine = "-m `"$($m.File)`" -ngl 99 -fa on -c $ctx -a $($m.Alias) -np 1 -cram 24576 " +
               "--host 127.0.0.1 --port $($m.Port) --no-webui " +
               "--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.05 --presence-penalty 1.0 --repeat-penalty 1.0"

    $outLog = Join-Path $LogDir "serve-$Key.out.log"
    $errLog = Join-Path $LogDir "serve-$Key.err.log"

    $p = Start-Process -FilePath $exe -ArgumentList $argLine `
         -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -NoNewWindow

    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 1000
        if (Test-Endpoint $m.Port) {
            return [pscustomobject]@{ Ok=$true; Code=0; Message="$($m.Name) 已就绪"; Pid=$p.Id; Ctx=$ctx }
        }
        if ($p.HasExited) { break }
    }

    $tail = ''
    if (Test-Path -LiteralPath $errLog) { $tail = (Get-Content -LiteralPath $errLog -Tail 8 -Encoding UTF8) -join "`n" }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ Ok=$false; Code=3; Message="启动超时或失败"; Pid=$null; Detail=$tail }
}

function Stop-LlmModel {
    $procs = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return [pscustomobject]@{ Ok=$true; Code=0; Stopped=@(); Message="没有 llama-server 在运行" } }

    $ids = @()
    foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $ids += $p.Id } catch {} }
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) { break }
    }
    $left = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Ok = ($left.Count -eq 0); Code = if ($left.Count -eq 0) { 0 } else { 6 }
        Stopped = $ids
        Message = if ($left.Count -eq 0) { "已停止 $($ids.Count) 个进程" } else { "仍有残留: $(($left.Id) -join ',')" }
    }
}

# ---------------------------------------------------------------- 核心：Ollama（三层）

function Get-OllamaStatus {
    $appProc = @(Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue)
    $srvProc = @(Get-Process -Name 'ollama' -ErrorAction SilentlyContinue)

    $apiOk = $false; $loaded = @(); $installed = @()
    try {
        $tags = Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2
        $apiOk = $true
        $installed = @($tags.models | ForEach-Object { $_.name })
        $ps = Invoke-RestMethod 'http://127.0.0.1:11434/api/ps' -TimeoutSec 2
        $loaded = @($ps.models | ForEach-Object {
            [pscustomobject]@{ Name = $_.name; VramMiB = [int](($_.size_vram) / 1MB) }
        })
    } catch {}

    [pscustomobject]@{
        AppRunning = ($appProc.Count -gt 0)
        AppPid     = if ($appProc.Count -gt 0) { $appProc[0].Id } else { $null }
        ServerRunning = ($srvProc.Count -gt 0)
        ServerPid  = if ($srvProc.Count -gt 0) { $srvProc[0].Id } else { $null }
        ApiOk      = $apiOk
        Port       = 11434
        Loaded     = $loaded
        Installed  = $installed
    }
}

function Start-Ollama {
    $st = Get-OllamaStatus
    if ($st.ApiOk) { return [pscustomobject]@{ Ok=$true; Code=0; Message="Ollama 已在线" } }

    # 优先启动托盘应用（ollama app.exe），它会自己拉起 serve；
    # 直接运行 ollama.exe 不会常驻，只会打印帮助后退出。
    $dir    = Split-Path -Parent $OllamaExe
    $appExe = Join-Path $dir 'ollama app.exe'
    if (Test-Path -LiteralPath $appExe) {
        Start-Process -FilePath $appExe | Out-Null
    } elseif (Test-Path -LiteralPath $OllamaExe) {
        Start-Process -FilePath $OllamaExe -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    } else {
        return [pscustomobject]@{ Ok=$false; Code=4; Message="找不到 Ollama 可执行文件: $dir" }
    }

    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 800
        if ((Get-OllamaStatus).ApiOk) { return [pscustomobject]@{ Ok=$true; Code=0; Message="Ollama 已启动" } }
    }
    [pscustomobject]@{ Ok=$false; Code=3; Message="Ollama 启动超时，请手动检查托盘应用" }
}

function Stop-OllamaModel {
    $st = Get-OllamaStatus
    if (-not $st.ApiOk) { return [pscustomobject]@{ Ok=$false; Code=5; Message="Ollama 服务未运行"; Unloaded=@() } }
    if ($st.Loaded.Count -eq 0) { return [pscustomobject]@{ Ok=$true; Code=0; Message="没有已加载的模型"; Unloaded=@() } }

    $names = @()
    foreach ($l in $st.Loaded) {
        & $OllamaExe stop $l.Name 2>&1 | Out-Null
        $names += $l.Name
    }
    Start-Sleep -Milliseconds 800
    [pscustomobject]@{ Ok=$true; Code=0; Message="已卸载: $($names -join ', ')"; Unloaded=$names }
}

function Stop-Ollama {
    $ids = @()
    foreach ($p in @(Get-Process -Name 'ollama','ollama app' -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $ids += $p.Id } catch {}
    }
    [pscustomobject]@{
        Ok = $true; Code = 0; Stopped = $ids
        Message = if ($ids.Count) { "已停止 Ollama（含托盘应用，需手动重开）" } else { "Ollama 本来就未运行" }
    }
}





