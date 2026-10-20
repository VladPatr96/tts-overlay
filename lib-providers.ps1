# lib-providers.ps1 — движки синтеза (OpenRouter, Яндекс, Edge, Silero, SAPI, Piper): запросы, воркеры, голоса, форматы.
# Подключается из tts-overlay.ps1 (dot-sourcing). Использует общее состояние главного скрипта: $Cfg, $Root, $script:ActiveProvider, $script:Http, $script:Models, воркеры ($script:EdgeWorker, $script:SileroWorker).

function Get-ProviderKey {
  # ключ счётчика: только он и показывается в интерфейсе
  if ($script:ActiveProvider -eq 'yandex') { return "yandex|$($Cfg.yandexVoice)" }
  if ($script:ActiveProvider -eq 'piper') { return "piper|$($Cfg.piperVoice)" }
  if ($script:ActiveProvider -eq 'silero') { return "silero|$($Cfg.sileroSpeaker)" }
  if ($script:ActiveProvider -eq 'edge') { return "edge|$($Cfg.edgeVoice)" }
  if ($script:ActiveProvider -eq 'sapi') { return "sapi|$($Cfg.sapiVoice)" }
  return "openrouter|$($Cfg.model)|$($Cfg.voice)"
}

function Get-ProviderLabel {
  $label = if ($script:ActiveProvider -eq 'yandex') { "Яндекс/$($Cfg.yandexVoice)" }
           elseif ($script:ActiveProvider -eq 'piper') { "Piper/$($Cfg.piperVoice)" }
           elseif ($script:ActiveProvider -eq 'silero') { "Silero/$($Cfg.sileroSpeaker)" }
           elseif ($script:ActiveProvider -eq 'edge') { "Edge/$($Cfg.edgeVoice)" }
           elseif ($script:ActiveProvider -eq 'sapi') { "SAPI/$($Cfg.sapiVoice)" }
           else { "OpenRouter/$($Cfg.model)" }
  if ($script:ActiveProvider -ne [string]$Cfg.provider) { $label += ' (запасной)' }
  return $label
}

function Resolve-Provider([string]$Text) {
  # локальные русские модели не умеют читать английские слова — если в тексте
  # есть латиница, озвучиваем через Яндекс
  $script:ActiveProvider = [string]$Cfg.provider
  if ($script:ActiveProvider -in @('silero', 'piper') -and $Cfg.fallbackToYandex -and $Cfg.yandexKey -and ($Text -match '[A-Za-z]')) {
    $script:ActiveProvider = 'yandex'
    Write-Log 'fallback: в тексте есть английские слова — озвучиваю через Яндекс'
    return $true
  }
  return $false
}

function Test-PcmModel([string]$ModelId) {
  # эти модели отдают только несжатый звук (pcm), mp3 они не умеют
  return ($ModelId -match '^google/gemini.*tts')
}

function Get-EffectiveFormat {
  # Яндексу заказываем несжатый звук: в него легко добавить тишину в начале,
  # которую «съедает» прогрев плеера, и речь не теряет первые слова
  if ($Cfg.provider -in @('yandex', 'piper', 'silero', 'edge', 'sapi')) { return 'wav' }
  if ($Cfg.provider -eq 'openrouter' -and (Test-PcmModel $Cfg.model)) { return 'wav' }
  return [string]$Cfg.format
}

function Get-PiperVoices {
  $result = @()
  try {
    if (Test-Path $Cfg.piperVoicesDir) {
      $result = @(Get-ChildItem $Cfg.piperVoicesDir -Filter '*.onnx' -File | ForEach-Object { $_.BaseName } | Sort-Object)
    }
  } catch { }
  if (-not $result.Count) { $result = @('ru_RU-dmitri-medium') }
  return $result
}

function Read-WavInfo([string]$Path) {
  # разбираем RIFF: ищем fmt и data (у SAPI fmt-чанк 18 байт, у Edge — обычный WAV)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 44) { throw 'не похоже на WAV' }
  $pos = 12
  $rate = 22050; $channels = 1; $bits = 16; $dataOffset = -1; $dataSize = 0
  while ($pos + 8 -le $bytes.Length) {
    $id = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 4)
    $size = [BitConverter]::ToInt32($bytes, $pos + 4)
    if ($id -eq 'fmt ' -and $size -ge 16) {
      $channels = [BitConverter]::ToInt16($bytes, $pos + 10)
      $rate = [BitConverter]::ToInt32($bytes, $pos + 12)
      $bits = [BitConverter]::ToInt16($bytes, $pos + 22)
    } elseif ($id -eq 'data') {
      $dataOffset = $pos + 8
      $dataSize = [Math]::Min($size, $bytes.Length - $dataOffset)
      break
    }
    $pos += 8 + $size + ($size % 2)
  }
  if ($dataOffset -lt 0) { throw 'в WAV нет data-чанка' }
  $pcm = if ($dataSize -gt 0) { $bytes[$dataOffset..($dataOffset + $dataSize - 1)] } else { [byte[]]::new(0) }
  return @{ Rate = $rate; Channels = $channels; Bits = $bits; Pcm = $pcm }
}

function Convert-WavToStandard([string]$Source, [string]$Target, [double]$LeadSeconds = 0.5) {
  $parsed = Read-WavInfo $Source
  ConvertTo-WavFile -Pcm $parsed.Pcm -Path $Target -SampleRate $parsed.Rate -Channels $parsed.Channels -Bits $parsed.Bits -LeadSeconds $LeadSeconds
}

function Get-SapiVoices {
  $result = @()
  try {
    $voice = New-Object -ComObject SAPI.SpVoice
    for ($i = 0; $i -lt $voice.GetVoices().Count; $i++) {
      $result += $voice.GetVoices().Item($i).GetDescription()
    }
  } catch { Write-Log "sapi: голоса не получились ($($_.Exception.Message))" }
  if (-not $result.Count) { $result = @('Microsoft Irina Desktop - Russian') }
  return $result
}

function Get-EdgeVoices {
  $result = @()
  try {
    $file = Join-Path $Root 'edge\voices.txt'
    if (Test-Path $file) {
      $result = @(Get-Content $file | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    }
  } catch { }
  if (-not $result.Count) { $result = @('ru-RU-DmitryNeural', 'ru-RU-SvetlanaNeural') }
  return $result
}

function Start-EdgeRequest([string]$Text, [bool]$AsSsml = $false) {
  if (-not (Start-EdgeWorker)) { throw 'воркер Edge не запустился' }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $reqFile = Join-Path $CacheDir "edge-$id.txt"
  [System.IO.File]::WriteAllText($reqFile, $Text, [System.Text.UTF8Encoding]::new($false))
  $mode = if ($AsSsml) { 'ssml' } else { 'text' }
  $script:EdgeWorker.StandardInput.WriteLine("$($Cfg.edgeVoice)|$reqFile|$mode|$($Cfg.edgeRate)|$($Cfg.edgePitch)")
  $script:EdgeWorker.StandardInput.Flush()
  return @{ RequestFile = $reqFile; OutFile = [System.IO.Path]::ChangeExtension($reqFile, '.wav'); ErrFile = "$reqFile.err"; Text = $Text }
}

function Start-SapiRequest([string]$Text) {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $reqFile = Join-Path $CacheDir "sapi-$id.txt"
  $outFile = Join-Path $CacheDir "sapi-$id.raw.wav"
  [System.IO.File]::WriteAllText($reqFile, $Text, [System.Text.UTF8Encoding]::new($false))
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = (Get-Command pwsh).Source
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($Cfg.sapiScript)`" -TextFile `"$reqFile`" -OutFile `"$outFile`" -Voice `"$($Cfg.sapiVoice)`""
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::new()
  $proc.StartInfo = $psi
  [void]$proc.Start()
  return @{ RequestFile = $reqFile; OutFile = $outFile; Proc = $proc; Text = $Text }
}

function Start-EdgeWorker([bool]$Quiet = $false) {
  if ($script:EdgeWorker -and -not $script:EdgeWorker.HasExited) { return $true }
  try {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Cfg.sileroPython
    $info.Arguments = "`"$($Cfg.edgeWorkerScript)`""
    $info.RedirectStandardInput = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    $script:EdgeWorker = $process
    Write-Log 'edge: воркер запущен'
    if (-not $Quiet) { Set-Status 'Edge: готовлю соединение…' }
    return $true
  } catch {
    Write-Log "edge: воркер не запустился ($($_.Exception.Message))"
    return $false
  }
}

function Get-LocalVoices {
  if ($script:ActiveProvider -eq 'silero') { return @('aidar', 'baya', 'kseniya', 'xenia', 'eugene') }
  if ($script:ActiveProvider -eq 'edge') { return @(Get-EdgeVoices) }
  if ($script:ActiveProvider -eq 'sapi') { return @(Get-SapiVoices) }
  return @(Get-PiperVoices)
}

function Get-PiperSampleRate {
  $cfgPath = Join-Path $Cfg.piperVoicesDir "$($Cfg.piperVoice).onnx.json"
  try {
    $voiceCfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    return [int]$voiceCfg.audio.sample_rate
  } catch { return 22050 }
}

function Get-LocalSampleRate {
  if ($script:ActiveProvider -eq 'silero') { return 48000 }
  return (Get-PiperSampleRate)
}

function Start-LocalSynthesis([string]$Text) {
  if ($script:ActiveProvider -eq 'silero') { return Start-SileroRequest $Text }
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $model = Join-Path $Cfg.piperVoicesDir "$($Cfg.piperVoice).onnx"
  $info.FileName = $Cfg.piperExe
  $info.Arguments = "--model `"$model`" --output_raw"
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.StandardInputEncoding = [System.Text.Encoding]::UTF8
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $info
  [void]$process.Start()
  $process.StandardInput.Write($Text)
  $process.StandardInput.Close()
  $null = $process.StandardError.ReadToEndAsync()
  $stream = [System.IO.MemoryStream]::new()
  $readTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
  return [pscustomobject]@{ Process = $process; Stream = $stream; Task = $readTask }
}

function Start-SileroWorker([bool]$Quiet = $false) {
  if ($script:SileroWorker -and -not $script:SileroWorker.HasExited -and $script:SileroModelLoaded -eq [string]$Cfg.sileroModel) { return $true }
  if ($script:SileroWorker) { try { $script:SileroWorker.Kill() } catch { } ; $script:SileroWorker = $null }
  try {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Cfg.sileroPython
    $info.Arguments = "`"$($Cfg.sileroWorkerScript)`" $($Cfg.sileroModel)"
    $info.RedirectStandardInput = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    $script:SileroWorker = $process
    $script:SileroModelLoaded = [string]$Cfg.sileroModel
    Write-Log "silero: воркер запущен, модель $($Cfg.sileroModel)"
    if (-not $Quiet) { Set-Status 'Silero: загружаю модель, первый раз ~15 секунд…' }
    return $true
  } catch {
    Write-Log "silero: воркер не запустился ($($_.Exception.Message))"
    return $false
  }
}

function Start-SileroRequest([string]$Text) {
  if (-not (Start-SileroWorker)) { throw 'не удалось запустить воркер Silero' }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $reqFile = Join-Path $CacheDir "silero-$id.txt"
  [System.IO.File]::WriteAllText($reqFile, $Text, [System.Text.UTF8Encoding]::new($false))
  $accent = if ($Cfg.sileroAccent) { '1' } else { '0' }
  $yo = if ($Cfg.sileroYo) { '1' } else { '0' }
  $script:SileroWorker.StandardInput.WriteLine("$($Cfg.sileroSpeaker)|$reqFile|$accent|$yo")
  $script:SileroWorker.StandardInput.Flush()
  return [pscustomobject]@{ RequestFile = $reqFile; PcmFile = [System.IO.Path]::ChangeExtension($reqFile, '.pcm'); Text = $Text }
}

function ConvertTo-WavFile {
  param(
    [byte[]]$Pcm,
    [string]$Path,
    [int]$SampleRate = 48000,
    [int]$Channels = 1,
    [int]$Bits = 16,
    [double]$LeadSeconds = 0.5
  )
  $blockAlign = $Channels * ($Bits / 8)
  $leadBytes = [int]($SampleRate * $blockAlign * $LeadSeconds)
  $dataLen = $Pcm.Length + $leadBytes
  $stream = [System.IO.File]::Create($Path)
  $writer = [System.IO.BinaryWriter]::new($stream)
  $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
  $writer.Write([int](36 + $dataLen))
  $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
  $writer.Write([int]16)
  $writer.Write([int16]1)
  $writer.Write([int16]$Channels)
  $writer.Write([int]$SampleRate)
  $writer.Write([int]($SampleRate * $blockAlign))
  $writer.Write([int16]$blockAlign)
  $writer.Write([int16]$Bits)
  $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
  $writer.Write([int]$dataLen)
  $writer.Write([byte[]]::new($leadBytes))
  $writer.Write($Pcm)
  $writer.Flush()
  $writer.Dispose()
  $stream.Dispose()
}

function New-TtsRequest([string]$Text) {
  if ($script:ActiveProvider -eq 'yandex') {
    if (-not $Cfg.yandexKey) { throw 'не задан ключ Яндекс SpeechKit (поле yandexKey в config.json)' }
    $form = [ordered]@{
      text           = $Text
      lang           = $Cfg.yandexLang
      voice          = $Cfg.yandexVoice
      format         = 'lpcm'
      sampleRateHertz = 48000
    }
    $speed = [double]$Cfg.yandexSpeed
    if ($speed -gt 0 -and [Math]::Abs($speed - 1.0) -gt 0.01) { $form.speed = ([string]$speed).Replace(',', '.') }
    if ($Cfg.yandexEmotion -and -not $script:YandexSkipEmotion) { $form.emotion = [string]$Cfg.yandexEmotion }
    $pairs = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string, string]]]::new()
    foreach ($name in $form.Keys) {
      $pairs.Add([System.Collections.Generic.KeyValuePair[string, string]]::new($name, [string]$form[$name]))
    }
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $YandexTtsUrl)
    $request.Content = [System.Net.Http.FormUrlEncodedContent]::new($pairs)
    [void]$request.Headers.TryAddWithoutValidation('Authorization', "Api-Key $($Cfg.yandexKey)")
    return $request
  }

  $payload = [ordered]@{ model = $Cfg.model; input = $Text; response_format = $Cfg.format }
  if (Test-PcmModel $Cfg.model) { $payload.response_format = 'pcm' }
  if ($Cfg.voice) { $payload.voice = $Cfg.voice }
  $json = $payload | ConvertTo-Json -Compress
  $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $ApiUrl)
  $request.Content = $content
  $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:OpenRouterKey)
  return $request
}

function Get-ErrorMessage([string]$Body) {
  try {
    $parsed = $Body | ConvertFrom-Json
    if ($parsed.error -and $parsed.error.message) { return $parsed.error.message }
    if ($parsed.error) { return "$($parsed.error)" }
  } catch { }
  $flat = ($Body -replace '\s+', ' ').Trim()
  if ($flat.Length -gt 160) { $flat = $flat.Substring(0, 160) + '…' }
  return $flat
}

function Load-Models {
  try {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $ModelsUrl)
    $script:ModelTask = $script:Http.SendAsync($request)
    Set-Status 'Загружаю список TTS-моделей…'
  } catch {
    Set-Status "Не загрузил список: $($_.Exception.Message)"
  }
}

function Get-VoiceFallback([string]$ModelId) {
  # в карточке бесплатной Fish Audio голосов нет, но параметр voice она понимает:
  # единственное рабочее имя — alloy (остальные дают 400)
  if ($ModelId -like 'fish-audio/*') { return @('alloy') }
  return @()
}
