#requires -version 7.0
<#
  stop-overlay.ps1 — останавливает оверлей озвучки, если он запущен.
      pwsh -File stop-overlay.ps1
#>
$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $Root 'tts-overlay.pid'

$stopped = @()

# 1. процесс из pid-файла
if (Test-Path $pidFile) {
  $overlayPid = 0
  if ([int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$overlayPid)) {
    if (Get-Process -Id $overlayPid -ErrorAction SilentlyContinue) {
      Stop-Process -Id $overlayPid -Force -ErrorAction SilentlyContinue
      $stopped += $overlayPid
    }
  }
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# 2. все прочие экземпляры (мог остаться от прошлых запусков).
#    -Command отсекаем: так запускаются консольные сессии, их трогать нельзя
$mine = $PID
$stray = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object {
  $_.ProcessId -ne $mine -and $_.CommandLine -and
  $_.CommandLine -notlike '*-Command*' -and
  $_.CommandLine -like '*-File*' -and
  $_.CommandLine -like '*tts-overlay*'
}
foreach ($p in $stray) {
  Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  $stopped += $p.ProcessId
}

# 3. локальные воркеры синтеза (silero/edge) — они живут отдельными процессами
foreach ($pattern in 'silero-worker.py', 'edge-worker.py') {
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine -like "*$pattern*"
  } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    $stopped += $_.ProcessId
  }
}

Start-Sleep -Milliseconds 700
if ($stopped.Count) { Write-Host "остановлено: $(($stopped | Sort-Object -Unique) -join ', ')" } else { Write-Host 'оверлей не был запущен' }
