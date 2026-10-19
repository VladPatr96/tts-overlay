#requires -version 7.0
<#
  install.ps1 — ставит оверлей озвучки в автозапуск и (по желанию) на рабочий стол.

      pwsh -File install.ps1                # ярлык в автозапуске + запустить сейчас
      pwsh -File install.ps1 -Desktop       # ещё и ярлык на рабочем столе
      pwsh -File install.ps1 -NoStart       # без немедленного запуска
      pwsh -File install.ps1 -Remove        # убрать ярлыки автозапуска
#>
param(
  [switch]$Desktop,
  [switch]$NoStart,
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script   = Join-Path $Root 'tts-overlay.ps1'
$Startup  = [Environment]::GetFolderPath('Startup')
$Shortcut = Join-Path $Startup 'Озвучка выделенного.lnk'
$DesktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Озвучка выделенного.lnk'
$Pwsh = (Get-Command pwsh).Source

function New-Link([string]$Path) {
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($Path)
  $link.TargetPath = $Pwsh
  $link.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script
  $link.WorkingDirectory = $Root
  $link.IconLocation = "$Pwsh,0"
  $link.Description = 'Озвучка выделенного текста через OpenRouter TTS'
  $link.Save()
  Write-Host "создан ярлык: $Path"
}

if ($Remove) {
  foreach ($path in @($Shortcut, $DesktopLink)) {
    if (Test-Path $path) { Remove-Item $path -Force; Write-Host "удалён ярлык: $path" }
  }
  exit 0
}

if (-not (Test-Path $Script)) { throw "Не нашёл $Script" }

New-Link $Shortcut
if ($Desktop) { New-Link $DesktopLink }

if (-not $NoStart) {
  $pidFile = Join-Path $Root 'tts-overlay.pid'
  $running = $false
  if (Test-Path $pidFile) {
    $overlayPid = 0
    if ([int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$overlayPid)) {
      $running = [bool](Get-Process -Id $overlayPid -ErrorAction SilentlyContinue)
    }
  }
  if ($running) {
    Write-Host 'оверлей уже запущен'
  } else {
    Start-Process -FilePath $Pwsh -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $Script)
    Write-Host 'оверлей запущен'
  }
}

Write-Host ''
Write-Host 'Готово. Горячие клавиши: Ctrl+Alt+S — выделенное, Ctrl+Alt+D — буфер, Ctrl+Alt+X — стоп.'
Write-Host "Настройки и кэш: $Root"
