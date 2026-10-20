# lib-core.ps1 — лог, конфиг и ключи. Подключается из tts-overlay.ps1 (dot-sourcing).
# Использует общее состояние главного скрипта: $Root, $LogPath, $ConfigPath, $Cfg.

function Write-Log([string]$Message) {
  try {
    Add-Content -Path $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8
  } catch { }
}

function Get-DefaultConfig {
  $defaults = [ordered]@{
    provider            = 'yandex'
    model               = 'fish-audio/s2.1-pro-free:free'
    voice               = 'alloy'
    yandexKey           = ''
    yandexVoice         = 'alena'
    yandexLang          = 'ru-RU'
    yandexRubPer1kChars = 1.342
    yandexBalanceStart  = 0
    yandexSpentAtStart  = 0
    fallbackToYandex    = $true
    piperExe            = (Join-Path $Root 'piper\app\piper\piper.exe')
    piperVoicesDir      = (Join-Path $Root 'piper\voices')
    piperVoice          = 'ru_RU-dmitri-medium'
    sileroPython        = 'python'
    sileroScript        = (Join-Path $Root 'silero\silero-tts.py')
    sileroWorkerScript  = (Join-Path $Root 'silero\silero-worker.py')
    sileroSpeaker       = 'kseniya'
    sileroModel         = 'v5_ru'
    edgeVoice           = 'ru-RU-DmitryNeural'
    edgeWorkerScript    = (Join-Path $Root 'edge\edge-worker.py')
    sapiVoice           = 'Microsoft Irina Desktop - Russian'
    sapiScript          = (Join-Path $Root 'sapi\sapi-speak.ps1')
    readNumbers         = $true
    englishAsEnglish    = $true
    yandexSpeed         = 1.0
    yandexEmotion       = ''
    edgeRate            = '+0%'
    edgePitch           = '+0Hz'
    sileroAccent        = $true
    sileroYo            = $true
    format              = 'mp3'
    speed               = 1.0
    maxCharsPerRequest  = 4000
    cacheMaxMB          = 200
    speakSelectionHotkey = 'Ctrl+Alt+S'
    speakClipboardHotkey = 'Ctrl+Alt+D'
    stopHotkey           = 'Ctrl+Alt+X'
    sttProvider          = 'openrouter'
    sttModel             = 'google/gemini-3.5-flash-lite'
    sttWhisperModel      = 'base'
    sttLang              = 'ru'
    sttHotkey            = 'Ctrl+Alt+V'
    sttMaxSeconds        = 60
    sttSampleRate        = 16000
    sttWorkerScript      = (Join-Path $Root 'stt\stt-worker.py')
    sttPrompt            = 'Расшифруй аудио на русском языке. Выведи только расшифровку, без пояснений.'
    window               = [pscustomobject]@{ left = $null; top = $null }
  }
  return $defaults
}

function Import-Config {
  $defaults = Get-DefaultConfig
  $Cfg = [pscustomobject]$defaults
  if (Test-Path $ConfigPath) {
    try {
      $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
      foreach ($prop in $saved.PSObject.Properties) {
        if ($prop.Name -eq 'window') {
          if ($prop.Value) {
            if ($null -ne $prop.Value.left) { $Cfg.window.left = $prop.Value.left }
            if ($null -ne $prop.Value.top)  { $Cfg.window.top  = $prop.Value.top }
          }
        } elseif ($Cfg.PSObject.Properties.Name -contains $prop.Name) {
          $Cfg.$($prop.Name) = $prop.Value
        }
      }
    } catch { Write-Log "config: не прочитан ($($_.Exception.Message))" }
  }
  return $Cfg
}

function Save-Config {
  try {
    ($Cfg | ConvertTo-Json -Depth 5) | Set-Content -Path $ConfigPath -Encoding utf8
  } catch { Write-Log "config: не сохранён ($($_.Exception.Message))" }
}

function Get-ApiKey {
  if ($env:OPENROUTER_API_KEY) { return $env:OPENROUTER_API_KEY }
  foreach ($candidate in @(
      (Join-Path $env:USERPROFILE '.local\share\opencode\auth.json'),
      (Join-Path $env:APPDATA 'opencode\auth.json')
    )) {
    if (Test-Path $candidate) {
      try {
        $auth = Get-Content $candidate -Raw | ConvertFrom-Json
        if ($auth.openrouter -and $auth.openrouter.key) { return $auth.openrouter.key }
      } catch { }
    }
  }
  throw 'Не нашёл ключ OpenRouter: задай переменную OPENROUTER_API_KEY или подключи OpenRouter в OpenCode.'
}
