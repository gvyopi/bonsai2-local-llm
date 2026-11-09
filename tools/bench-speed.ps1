#requires -Version 7.0
<#
  bench-speed.ps1 — 带预热与时钟检查的测速（口径见《本地模型风险清单》§6.4）

  为什么需要它：
    笔记本 GPU 空闲时核心时钟可低至 ~210 MHz（上限 3105）。模型刚加载完就计时，
    会把 50 tok/s 读成二三十。本脚本先热身到时钟稳定，再跑固定长度的任务，
    最后把「任务类型 + 生成长度 + 时钟」一起报出来 —— 这样数字才有可比性。

  用法：
    .\tools\bench-speed.ps1                                  # 默认 27B @ 8081，prog 任务
    .\tools\bench-speed.ps1 -Task prose                      # 换任务类型
    .\tools\bench-speed.ps1 -Url http://127.0.0.1:8080/v1/chat/completions -Model bonsai-2-9b
    .\tools\bench-speed.ps1 -NoWarmup -MaxTok 256            # 只取一个冷读数做对照

  判读：
    * 时钟比值 < 0.9  → 读数偏低，加大 -WarmupSeconds 重跑，别拿去对比
    * 引擎自报（timings.predicted_per_second）比外部计时可靠，后者含首 token 等待
    * 换配置前后对比时，任务、-MaxTok、预热时长必须保持一致
#>
param(
    [ValidateSet('prog', 'prose', 'count')][string]$Task = 'prog',
    [string]$Url = 'http://127.0.0.1:8081/v1/chat/completions',
    [string]$Model = 'bonsai-2-27b',
    [int]$MaxTok = 1024,
    [int]$WarmupSeconds = 30,
    [switch]$NoWarmup
)

$ErrorActionPreference = 'Stop'

$Tasks = @{
    prog  = @{
        Name   = 'prog — 生成 PowerShell 脚本（中长输出，接近真实编码任务）'
        Prompt = '用 PowerShell 写一个函数 Get-DirStat：递归统计指定目录下每种扩展名的文件数和总字节数，按总字节降序输出为对象数组，包含错误处理（无权限目录跳过）。只输出代码，不要解释。'
    }
    prose = @{
        Name   = 'prose — 中文说明文（约 400 字，接近日常写作）'
        Prompt = '用中文写一篇约 400 字的说明，解释本地部署大模型时显存预算的四个组成部分（权重、注意力状态、KV 缓存、计算缓冲），要求分点、并给出具体数字示例。'
    }
    count = @{
        Name   = 'count — 数数字（输出长度最稳定，适合做横向对比）'
        Prompt = '从 1 数到 400，每个数字后面加一个中文顿号，不要任何解释，不要换行。'
    }
}

function Get-GpuClock {
    $raw = & nvidia-smi --query-gpu=clocks.sm,clocks.max.sm --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return $null }
    $p = @(($raw -split ',') | ForEach-Object { [int]($_ -replace '[^0-9]', '') })
    if ($p.Count -lt 2 -or $p[1] -le 0) { return $null }
    [pscustomobject]@{
        Sm    = $p[0]
        Max   = $p[1]
        Ratio = [math]::Round($p[0] / $p[1], 2)
    }
}

function Format-Clock {
    param($C)
    if (-not $C) { return '不可用（nvidia-smi 无返回）' }
    '{0} / {1} MHz  ({2:P0})' -f $C.Sm, $C.Max, $C.Ratio
}

function Send-Chat {
    param([string]$Prompt, [int]$MaxTokens)

    $body = @{
        model       = $Model
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $MaxTokens
        temperature = 0.0
        stream      = $false
    } | ConvertTo-Json -Depth 8 -Compress

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri $Url -Method Post -Body $body `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec 1800
    $sw.Stop()
    [pscustomobject]@{ Resp = $r; Seconds = $sw.Elapsed.TotalSeconds }
}

# ---------------------------------------------------------------- 前置检查

if (-not $Tasks.ContainsKey($Task)) { "未知任务: $Task"; exit 2 }
$T = $Tasks[$Task]

"=== 测速 ==="
"  任务: $($T.Name)"
"  模型: $Model    输出上限: $MaxTok tokens"
""

try {
    $null = Invoke-RestMethod -Uri ($Url -replace '/v1/chat/completions$', '/v1/models') `
        -Method Get -TimeoutSec 10
} catch {
    "服务不可达: $Url"
    "  先启动：pwsh -File .\llmctl.ps1 start 27b"
    exit 3
}

# ---------------------------------------------------------------- 预热

$clockBefore = Get-GpuClock
if ($NoWarmup) {
    "  预热: 跳过（-NoWarmup），本读数可能偏低"
} else {
    "  预热: 目标 ${WarmupSeconds}s，等待时钟拉到 ≥90% ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rounds = 0
    while ($sw.Elapsed.TotalSeconds -lt $WarmupSeconds) {
        $rounds++
        $null = Send-Chat -Prompt "Write one short English sentence about the number $rounds." -MaxTokens 64
    }
    $clockAfterWarm = Get-GpuClock
    "  预热: 完成 $rounds 轮 / $([math]::Round($sw.Elapsed.TotalSeconds,1))s，时钟 $(Format-Clock $clockAfterWarm)"
}
""

# ---------------------------------------------------------------- 计时

$clockBefore = Get-GpuClock
try {
    $res = Send-Chat -Prompt $T.Prompt -MaxTokens $MaxTok
} catch {
    "请求失败: $($_.Exception.Message)"
    exit 4
}
$clockAfter = Get-GpuClock

$resp   = $res.Resp
$msg    = $resp.choices[0].message
$finish = $resp.choices[0].finish_reason
$ct     = if ($resp.usage.completion_tokens) { [int]$resp.usage.completion_tokens } else { 0 }
$pt     = if ($resp.usage.prompt_tokens) { [int]$resp.usage.prompt_tokens } else { 0 }
$rl     = if ($msg.reasoning_content) { $msg.reasoning_content.Length } else { 0 }
$cl     = if ($msg.content) { $msg.content.Length } else { 0 }
$extTps = if ($ct -gt 0 -and $res.Seconds -gt 0) { [math]::Round($ct / $res.Seconds, 1) } else { 0 }

$engineTps = $null
$engMs = $null
if ($resp.timings) {
    $engineTps = $resp.timings.predicted_per_second
    $engMs = $resp.timings.predicted_ms
}

# ---------------------------------------------------------------- 报告

'--- 读数 ---'
'  时钟（测前）: {0}' -f (Format-Clock $clockBefore)
'  时钟（测后）: {0}' -f (Format-Clock $clockAfter)
''
'  prompt_tokens  : {0}' -f $pt
'  completion     : {0} tokens（思考 {1} 字符 / 正文 {2} 字符）' -f $ct, $rl, $cl
'  finish_reason  : {0}' -f $finish
''

if ($null -ne $engineTps) {
    '  引擎自报       : {0:N1} tok/s（{1} tokens / {2:N2} s）' -f $engineTps, $ct, ($engMs / 1000)
} else {
    '  引擎自报       : 不可用（本次响应无 timings 字段）'
}
'  外部计时       : {0:N1} tok/s（总耗时 {1:N2} s，含首 token 等待）' -f $extTps, $res.Seconds
''

$free = $null
$rawMem = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null
if ($rawMem) {
    $mp = @(($rawMem -split ',') | ForEach-Object { [int]($_ -replace '[^0-9]', '') })
    if ($mp.Count -ge 2) { $free = $mp[1] - $mp[0] }
}
if ($null -ne $free) { '  显存余量       : {0} MiB' -f $free }

# ---------------------------------------------------------------- 判定

$ratio = if ($clockAfter) { $clockAfter.Ratio } else { 1.0 }
''
if ($ratio -ge 0.9) {
    '  判定: 时钟已拉满，读数可用'
} else {
    '  判定: 时钟仅 {0:P0}，读数偏低 —— 加大 -WarmupSeconds 重跑，勿用于横向对比' -f $ratio
}
if ($ct -lt 512) {
    '  注意: 只生成 {0} tokens，样本偏短（口径要求 ≥512），结论仅供参考' -f $ct
}
if ($finish -eq 'length') {
    '  注意: finish_reason=length，输出被 MaxTok 截断；要测纯解码速度请加大 -MaxTok'
}
