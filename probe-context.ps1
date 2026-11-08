#requires -Version 7.0
<#
  probe-context.ps1 — find the maximum usable context for a GGUF model on this GPU.

  Runs llama-cli at a ladder of context sizes, records peak VRAM and generation
  speed, and reports the largest size that actually works. This is the standard
  first action after swapping in a new model: the numbers it prints replace guessing.

  Examples:
    & .\probe-context.ps1
    & .\probe-context.ps1 -Ctx 4096,16384,65536,131072
    & .\probe-context.ps1 -Model '.\models\other.gguf' -N 64
#>
[CmdletBinding()]
param(
    [int[]]  $Ctx        = @(4096, 8192, 16384, 32768, 65536, 131072),
    [int]    $N          = 16,
    [string] $Model      = (Join-Path $PSScriptRoot 'models\Ternary-Bonsai-2-9B-PQ2_0.gguf'),
    [string] $App        = (Join-Path $PSScriptRoot 'app'),
    [int]    $TimeoutSec = 300
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Model)) { throw "Model not found: $Model" }
$exe = Join-Path $App 'llama-cli.exe'
if (-not (Test-Path -LiteralPath $exe))    { throw "llama-cli.exe not found: $exe" }

# Total VRAM as reported by the driver, used to compute the headroom column.
$totalMiB = 0
$raw = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
if ($raw) { $totalMiB = [int]($raw -replace '[^0-9]', '') }
if ($totalMiB -le 0) { $totalMiB = 8192 }

function Get-UsedMiB {
    $r = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
    if (-not $r) { return 0 }
    return [int]($r -replace '[^0-9]', '')
}

$results = [System.Collections.Generic.List[object]]::new()
$tmp = Join-Path $env:TEMP ('llamacpp-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host ""
Write-Host ("model  : " + (Split-Path $Model -Leaf))
Write-Host ("size   : {0:N0} MiB" -f ((Get-Item -LiteralPath $Model).Length / 1MB))
Write-Host ("vram   : {0} MiB total" -f $totalMiB)
Write-Host ""

foreach ($c in $Ctx) {
    $log = Join-Path $tmp "ctx-$c.out.log"
    $err = Join-Path $tmp "ctx-$c.err.log"

    # One argument string, fully quoted: Start-Process -ArgumentList joins array
    # elements with spaces, which silently shreds any argument containing spaces.
    # -v is required: without it llama.cpp prints only the friendly banner to
    # stdout and the loader summary (layer offload, n_ctx) is never emitted.
    $argLine = '-m "{0}" -ngl 99 -fa on -c {1} -n {2} -st -rea off -v --temp 0.7 --min-p 0 -p "Say OK."' -f $Model, $c, $N

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $exe -ArgumentList $argLine `
        -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -NoNewWindow

    $peak = 0
    while (-not $proc.HasExited) {
        $u = Get-UsedMiB
        if ($u -gt $peak) { $peak = $u }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            try { $proc.Kill() } catch { }
            break
        }
        Start-Sleep -Milliseconds 400
    }
    try { $proc.WaitForExit(5000) | Out-Null } catch { }
    $sw.Stop()

    $text = ''
    if (Test-Path $log) { $text += (Get-Content $log -Raw -Encoding UTF8) }
    if (Test-Path $err) { $text += (Get-Content $err -Raw -Encoding UTF8) }

    $failed =
        $text -match '(?i)(out of memory|failed to allocate|cuda error|unknown model|invalid argument|error:)' -or
        $peak -ge ($totalMiB - 64)

    $gen = ''
    if ($text -match 'Generation:\s*([\d.]+)\s*t/s') { $gen = $Matches[1] }
    $offload = ''
    if ($text -match 'offloaded\s+(\d+)/(\d+)\s+layers to GPU') { $offload = "$($Matches[1])/$($Matches[2])" }

    $status = if ($failed) { 'FAIL' } else { 'OK' }
    $results.Add([pscustomobject]@{
        ctx     = $c
        status  = $status
        vramMiB = $peak
        headroom = $totalMiB - $peak
        genTps  = $gen
        offload = $offload
        secs    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    })

    Write-Host ("{0,-8} {1,-5} peak={2,6} MiB  free={3,6} MiB  gen={4,7} t/s  layers={5,-7} {6}s" -f `
        $c, $status, $peak, ($totalMiB - $peak), $gen, $offload, [math]::Round($sw.Elapsed.TotalSeconds, 1))

    if ($failed -and $c -ge 16384) { break }   # stop climbing once it breaks
}

Write-Host ""
Write-Host "=== summary ==="
$results | Format-Table ctx, status, vramMiB, headroom, genTps, offload -AutoSize | Out-String | Write-Host

$ok = $results | Where-Object { $_.status -eq 'OK' }
if ($ok) {
    $max = ($ok | Measure-Object ctx -Maximum).Maximum
    $recommended = [int]($max / 2)
    if ($recommended -lt 4096) { $recommended = 4096 }
    Write-Host ("largest working ctx : {0}" -f $max)
    Write-Host ("suggested daily ctx : {0}  (leaves room for longer prompts)" -f $recommended)
} else {
    Write-Host "no configuration succeeded - check the log files:"
    Write-Host ("  " + $tmp)
}

Write-Host ""
Write-Host ("logs kept in: " + $tmp)


