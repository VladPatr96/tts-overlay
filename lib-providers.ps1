# lib-providers.ps1 — движки синтеза (OpenRouter, Яндекс, Edge, Silero, SAPI, Piper): запросы, воркеры, голоса, форматы.
# Подключается из tts-overlay.ps1 (dot-sourcing). Использует общее состояние главного скрипта: $Cfg, $Root, $script:ActiveProvider, $script:Http, $script:Models, воркеры ($script:EdgeWorker, $script:SileroWorker).

# Карта движков: одна запись — один движок. Чтобы добавить движок, нужна запись здесь и воркер/запрос (см. README).
# Поля записи:
#   Title        — подпись в списке источников            Label/Source — подпись активного голоса (интерфейс/лог запуска)
#   VoiceKey     — поле $Cfg с голосом                     UsageKey     — ключ счётчика затрат (если не «id|голос»)
#   Voices       — блок: список голосов (нет — голоса у модели)   VoiceTitles — блок: имя → подпись (если голоса с подписями)
#   Tooltip/Info — подсказка списка голосов / строка под ним      Kind         — http | file | pipe | silero
#   Start        — блок запуска синтеза (для локальных: Speech, Index, Path → элемент очереди)
#   Request      — блок запроса (для http)                 Format       — блок: формат файла в кэше
#   WavFromRaw   — ответ — сырой PCM, заворачиваем в wav   Cost        — блок: стоимость куска (Chars → rub/usd)
#   Currency     — rub | usd | '' (бесплатный)             Free/Local   — бесплатный / работает локально
#   RussianOnly  — не читает английские слова              Fallbackable — при сбое можно озвучить запасным движком
#   Ready        — блок: можно ли использовать (ключ есть)  HasModels    — есть список моделей OpenRouter
#   Warmup       — блок: что поднять при старте            StampParts/CacheParts — что добавить в ключ кэша
#   LineExtra/DetailsExtra — блоки: дописать строку/подробности затрат
function Get-ProviderMap {
  $map = [ordered]@{}
  $map['yandex'] = @{
    Title = 'Яндекс SpeechKit'
    Label = { "Яндекс/$($Cfg.yandexVoice)" }
    Source = { "яндекс/$($Cfg.yandexVoice)" }
    VoiceKey = 'yandexVoice'
    Voices = { @($script:YandexVoices.Keys) }
    VoiceTitles = { $script:YandexVoices }
    Tooltip = 'Голос Яндекс SpeechKit.'
    Info = { "Яндекс SpeechKit · $($Cfg.yandexLang) · голос $($Cfg.yandexVoice)" }
    Kind = 'http'
    Request = { param($Text) New-YandexRequest $Text }
    Format = { 'wav' }
    WavFromRaw = $true
    Cost = { param($Chars) @{ rub = ($Chars / 1000.0) * [double]$Cfg.yandexRubPer1kChars; usd = 0.0 } }
    Currency = 'rub'
    Free = $false; Local = $false; RussianOnly = $false; Fallbackable = $false
    Ready = { [bool]$Cfg.yandexKey }
    HasModels = $false
    StampParts = { @($Cfg.yandexSpeed, $Cfg.yandexEmotion) }
    CacheParts = { "|$($Cfg.yandexLang)" }
    DetailsExtra = {
      param($Entry, $Balance, $Rate)
      if ([double]$Cfg.yandexBalanceStart -gt 0) {
        $left = [double]$Cfg.yandexBalanceStart - ([double]$Entry.rub - [double]$Cfg.yandexSpentAtStart)
        "Яндекс: осталось ≈ {0} (введено вручную {1})" -f (Format-Rub $left), (Format-Rub ([double]$Cfg.yandexBalanceStart))
      }
    }
  }
  $map['edge'] = @{
    Title = 'Edge TTS (бесплатно)'
    Label = { "Edge/$($Cfg.edgeVoice)" }
    Source = { "edge/$($Cfg.edgeVoice)" }
    VoiceKey = 'edgeVoice'
    Voices = { @(Get-EdgeVoices) }
    Tooltip = 'Локальный голос (работает без интернета).'
    Info = { "Edge TTS · бесплатно · $($Cfg.edgeVoice)" }
    Kind = 'file'
    Start = {
      param($Speech, $Index, $Path)
      $ssml = ConvertTo-Ssml -Text $Speech -Pronounce $script:Pronounce -EnglishAsEnglish ([bool]$Cfg.englishAsEnglish)
      $req = Start-EdgeRequest $ssml $true
      [pscustomobject]@{ Index = $Index; Path = $Path; Kind = 'file'; Req = $req; Requested = (Get-Date) }
    }
    Format = { 'wav' }
    Cost = { param($Chars) @{ rub = 0.0; usd = 0.0 } }
    Currency = ''
    Free = $true; Local = $false; RussianOnly = $false; Fallbackable = $true
    Ready = { $true }
    HasModels = $false
    Warmup = { Start-EdgeWorker $true }
  }
  $map['silero'] = @{
    Title = 'Silero (локально, бесплатно)'
    Label = { "Silero/$($Cfg.sileroSpeaker)" }
    Source = { "silero/$($Cfg.sileroSpeaker)" }
    VoiceKey = 'sileroSpeaker'
    Voices = { @('aidar', 'baya', 'kseniya', 'xenia', 'eugene') }
    Tooltip = 'Локальный голос (работает без интернета).'
    Info = { "Silero · локально · $($Cfg.sileroSpeaker)" }
    Kind = 'silero'
    Start = {
      param($Speech, $Index, $Path)
      $req = Start-SileroRequest $Speech
      [pscustomobject]@{ Index = $Index; Path = $Path; Kind = 'silero'; Req = $req }
    }
    Format = { 'wav' }
    Cost = { param($Chars) @{ rub = 0.0; usd = 0.0 } }
    Currency = ''
    Free = $true; Local = $true; RussianOnly = $true; Fallbackable = $true
    Ready = { $true }
    HasModels = $false
    Warmup = { Start-SileroWorker $true }
    DetailsExtra = { param($Entry, $Balance, $Rate) 'Silero: локальный синтез, интернет и оплата не нужны' }
  }
  $map['sapi'] = @{
    Title = 'SAPI 5 (встроенный в Windows)'
    Label = { "SAPI/$($Cfg.sapiVoice)" }
    Source = { "sapi/$($Cfg.sapiVoice)" }
    VoiceKey = 'sapiVoice'
    Voices = { @(Get-SapiVoices) }
    Tooltip = 'Локальный голос (работает без интернета).'
    Info = { "SAPI 5 · встроенный голос · $($Cfg.sapiVoice)" }
    Kind = 'file'
    Start = {
      param($Speech, $Index, $Path)
      $req = Start-SapiRequest $Speech
      [pscustomobject]@{ Index = $Index; Path = $Path; Kind = 'file'; Req = $req; Requested = (Get-Date) }
    }
    Format = { 'wav' }
    Cost = { param($Chars) @{ rub = 0.0; usd = 0.0 } }
    Currency = ''
    Free = $true; Local = $false; RussianOnly = $false; Fallbackable = $true
    Ready = { $true }
    HasModels = $false
  }
  $map['piper'] = @{
    Title = 'Piper (локально, бесплатно)'
    Label = { "Piper/$($Cfg.piperVoice)" }
    Source = { "piper/$($Cfg.piperVoice)" }
    VoiceKey = 'piperVoice'
    Voices = { @(Get-PiperVoices) }
    Tooltip = 'Локальный голос (работает без интернета).'
    Info = { "Piper · локально · $($Cfg.piperVoice)" }
    Kind = 'pipe'
    Start = {
      param($Speech, $Index, $Path)
      $pipe = Start-LocalSynthesis $Speech
      [pscustomobject]@{
        Index = $Index; Path = $Path; Task = $pipe.Task; Kind = 'pipe'; Pipe = $pipe
        SampleRate = (Get-PiperSampleRate)
      }
    }
    Format = { 'wav' }
    Cost = { param($Chars) @{ rub = 0.0; usd = 0.0 } }
    Currency = ''
    Free = $true; Local = $true; RussianOnly = $true; Fallbackable = $true
    Ready = { $true }
    HasModels = $false
    DetailsExtra = { param($Entry, $Balance, $Rate) 'Piper: локальный синтез, интернет и оплата не нужны' }
  }
  $map['openrouter'] = @{
    Title = 'OpenRouter (модели)'
    Label = { "OpenRouter/$($Cfg.model)" }
    Source = { "$($Cfg.model)/$($Cfg.voice)" }
    VoiceKey = 'voice'
    UsageKey = { "openrouter|$($Cfg.model)|$($Cfg.voice)" }
    Kind = 'http'
    Request = { param($Text) New-OpenRouterRequest $Text }
    Format = { if (Test-PcmModel $Cfg.model) { 'wav' } else { [string]$Cfg.format } }
    Cost = { param($Chars) @{ rub = 0.0; usd = $Chars * (Get-ModelPricePerChar) } }
    Currency = 'usd'
    Free = $false; Local = $false; RussianOnly = $false; Fallbackable = $true
    Ready = { $true }
    HasModels = $true
    Warmup = { Load-Models }
    LineExtra = {
      param($Balance, $Rate)
      if ($Balance.at) { "   ·   остаток {0} (≈ {1})" -f (Format-UsdWhole ([double]$Balance.left)), (Format-Rub ([double]$Balance.left * $Rate)) }
    }
    DetailsExtra = {
      param($Entry, $Balance, $Rate)
      if ($Balance.at) {
        "OpenRouter: осталось {0} из {1}, израсходовано {2} (обновлено {3})" -f (Format-UsdWhole ([double]$Balance.left)), (Format-UsdWhole ([double]$Balance.total)), (Format-UsdWhole ([double]$Balance.used)), $Balance.at
      }
    }
  }
  return $map
}

function Get-ActiveProvider { return $script:Providers[[string]$script:ActiveProvider] }

function Get-ConfiguredProvider { return $script:Providers[[string]$Cfg.provider] }

function Invoke-ProviderFallback($Item, [string]$Reason, [string]$FailStatus) {
  # движок не ответил: озвучиваем кусок запасным (Яндекс), если он доступен и сам не сбойнул;
  # иначе показываем $FailStatus и сбрасываем сессию
  $fallback = $script:Providers[$script:FallbackProviderId]
  if ((& $fallback.Ready) -and (Get-ActiveProvider).Fallbackable -and $Item.Req.Text) {
    Set-Status 'Движок не ответил — озвучиваю через Яндекс'
    Write-Log "fallback: $Reason, переключаюсь на Яндекс"
    Start-Speaking $Item.Req.Text 'запасной (Яндекс)' $script:FallbackProviderId
  } else {
    Set-Status $FailStatus
    $script:Session = $null
  }
}

function Get-ProviderKey {
  # ключ счётчика: только он и показывается в интерфейсе
  $provider = Get-ActiveProvider
  if ($provider.UsageKey) { return (& $provider.UsageKey) }
  return "$($script:ActiveProvider)|$($Cfg.($provider.VoiceKey))"
}

function Get-ProviderLabel {
  $label = & (Get-ActiveProvider).Label
  if ($script:ActiveProvider -ne [string]$Cfg.provider) { $label += ' (запасной)' }
  return $label
}

function Resolve-Provider([string]$Text) {
  # локальные русские модели не умеют читать английские слова — если в тексте
  # есть латиница, озвучиваем через запасной движок (Яндекс)
  $script:ActiveProvider = [string]$Cfg.provider
  $fallback = $script:Providers[$script:FallbackProviderId]
  if ((Get-ActiveProvider).RussianOnly -and $Cfg.fallbackToYandex -and (& $fallback.Ready) -and ($Text -match '[A-Za-z]')) {
    $script:ActiveProvider = $script:FallbackProviderId
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
  return (& (Get-ConfiguredProvider).Format)
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

function Get-PiperSampleRate {
  $cfgPath = Join-Path $Cfg.piperVoicesDir "$($Cfg.piperVoice).onnx.json"
  try {
    $voiceCfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    return [int]$voiceCfg.audio.sample_rate
  } catch { return 22050 }
}

function Start-LocalSynthesis([string]$Text) {
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
  return (& (Get-ActiveProvider).Request $Text)
}

function New-YandexRequest([string]$Text) {
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

function New-OpenRouterRequest([string]$Text) {
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
