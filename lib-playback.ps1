# lib-playback.ps1 — очередь кусков, кэш озвученного, воспроизведение (старт, стоп, пауза).
# Подключается из tts-overlay.ps1 (dot-sourcing). Использует общее состояние главного скрипта: $Cfg, $CacheDir, $script:Session, $script:Pending, $script:Player, $script:Speaking, элементы окна.

function Split-Text([string]$Text, [int]$Max) {
  $clean = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
  if ($Max -le 0) {
    $whole = ($clean -replace '[ \t]+', ' ').Trim()
    if ($whole) { return @($whole) }
    return @()
  }
  $units = [System.Collections.Generic.List[string]]::new()
  foreach ($para in ($clean -split "`n+")) {
    $para = ($para -replace '[ \t]+', ' ').Trim()
    if (-not $para) { continue }
    if ($units.Count) { $units.Add("`n") }
    foreach ($sentence in [regex]::Split($para, '(?<=[\.\!\?…\:;])\s+')) {
      $s = $sentence.Trim()
      if ($s) { $units.Add($s) }
    }
  }

  $parts  = [System.Collections.Generic.List[string]]::new()
  $buffer = ''
  foreach ($unit in $units) {
    if ($unit -eq "`n") {
      if ($buffer -and -not $buffer.EndsWith("`n")) { $buffer += "`n" }
      continue
    }
    if ($unit.Length -gt $Max) {
      # очень длинное предложение: режем по запятым/пробелам, а не по буквам
      if ($buffer.Trim()) { $parts.Add($buffer.Trim()) }
      $buffer = ''
      $rest = $unit
      while ($rest.Length -gt $Max) {
        $window = $rest.Substring(0, $Max)
        $cut = $window.LastIndexOfAny([char[]]@(',', ';', ':', '—', ' '))
        if ($cut -lt [int]($Max / 2)) { $cut = $window.LastIndexOf(' ') }
        if ($cut -lt 1) { $cut = $Max - 1 }
        $parts.Add($rest.Substring(0, $cut + 1).Trim())
        $rest = $rest.Substring($cut + 1).Trim()
      }
      $buffer = $rest
      continue
    }
    $separator = if (-not $buffer -or $buffer.EndsWith("`n")) { '' } else { ' ' }
    if (($buffer.Length + $separator.Length + $unit.Length) -gt $Max) {
      if ($buffer.Trim()) { $parts.Add($buffer.Trim()) }
      $buffer = $unit
      continue
    }
    $buffer = "$buffer$separator$unit"
  }
  if ($buffer.Trim()) { $parts.Add($buffer.Trim()) }
  return $parts
}

function Get-PronounceStamp {
  # отпечаток настроек произношения: меняем словарь или опции — кэш перестаёт совпадать.
  # скорость воспроизведения (плеера) сюда не входит: она не меняет сам звук
  $parts = @(
    $Cfg.readNumbers, $Cfg.englishAsEnglish, $Cfg.sileroAccent, $Cfg.sileroYo,
    $Cfg.edgeRate, $Cfg.edgePitch
  )
  $stamp = (Get-ConfiguredProvider).StampParts
  if ($stamp) { $parts += @(& $stamp) }
  $parts += ($script:Pronounce | ConvertTo-Json -Compress -Depth 4)
  $payload = $parts -join '|'
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-', '').Substring(0, 8)
}

function Get-CachePath([string]$Text) {
  # ключ: движок+голос, формат, настройки произношения и сам текст
  $who = Get-ProviderKey
  $extra = (Get-ConfiguredProvider).CacheParts
  if ($extra) { $who += (& $extra) }
  $material = '{0}|{1}|{2}|{3}' -f $who, (Get-EffectiveFormat), (Get-PronounceStamp), $Text
  $sha  = [System.Security.Cryptography.SHA1]::Create()
  $hash = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))).Replace('-', '').ToLowerInvariant()
  return (Join-Path $CacheDir ('{0}.{1}' -f $hash, (Get-EffectiveFormat)))
}

function Clear-CacheIfNeeded {
  try {
    $files = Get-ChildItem $CacheDir -File | Sort-Object LastWriteTime
    $limit = [double]$Cfg.cacheMaxMB * 1MB
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    while ($files.Count -and $total -gt $limit) {
      $old = $files[0]
      $total -= $old.Length
      Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
      $files = $files | Select-Object -Skip 1
    }
  } catch { }
}

function Request-More {
  if (-not $script:Session) { return }
  $session = $script:Session
  while ($session.Requested -lt $session.Chunks.Count -and $script:Pending.Count -lt 2) {
    $index = $session.Requested
    $text  = $session.Chunks[$index]
    $path  = Get-CachePath $text
    $session.Requested++
    if (Test-Path $path) { $session.Files[$index] = $path; continue }
    # приводим текст к произносимому виду: числа словами + словарь произношения
    $speech = Convert-SpeechText $text $script:Pronounce ([bool]$Cfg.readNumbers)
    $provider = Get-ActiveProvider
    if ($provider.Start) {
      try {
        $script:Pending.Add((& $provider.Start $speech $index $path))
        $preview = if ($speech.Length -gt 40) { $speech.Substring(0, 40) } else { $speech }
        Write-Log ("chunk {0} текст: {1}" -f $index, ($preview -replace '\s+', ' '))
        Add-Usage $speech
      } catch {
        Set-Status "Ошибка локального синтеза: $($_.Exception.Message)"
        Write-Log "local failed: $($_.Exception.Message)"
        $script:Session = $null
        return
      }
      continue
    }
    try {
      $task = $script:Http.SendAsync((New-TtsRequest $speech))
      $script:Pending.Add([pscustomobject]@{ Index = $index; Path = $path; Task = $task; Text = $speech })
      $preview = if ($speech.Length -gt 40) { $speech.Substring(0, 40) } else { $speech }
      Write-Log ("chunk {0} текст: {1}" -f $index, ($preview -replace '\s+', ' '))
      Add-Usage $speech
    } catch {
      Set-Status "Ошибка запроса: $($_.Exception.Message)"
      Write-Log "request failed: $($_.Exception.Message)"
      $script:Session = $null
      return
    }
  }
  Try-Play-Next
}

function Try-Play-Next {
  if (-not $script:Session -or $script:Speaking) { return }
  $session = $script:Session
  if ($session.Files.ContainsKey($session.Played)) {
    $path = $session.Files[$session.Played]
    $script:Speaking = $true
    try {
      $script:Player.SpeedRatio = [double]$Cfg.speed
      $script:Player.Open([uri]$path)
      $script:PendingPlay = $path
      $script:PendingPlayAt = Get-Date
      Set-Status ("Озвучиваю… {0}/{1}" -f ($session.Played + 1), $session.Chunks.Count)
      Write-Log ("open {0}/{1}: {2} байт" -f ($session.Played + 1), $session.Chunks.Count, (Get-Item $path).Length)
    } catch {
      $script:Speaking = $false
      Set-Status "Ошибка воспроизведения: $($_.Exception.Message)"
      Write-Log "play failed: $($_.Exception.Message)"
    }
  } elseif ($session.Requested -ge $session.Chunks.Count -and $script:Pending.Count -eq 0 -and $session.Played -ge $session.Chunks.Count) {
    Set-Status 'Готово'
    $script:Session = $null
  }
}

function Start-Speaking([string]$Text, [string]$Source = 'выделенное', [string]$Provider = '') {
  if (-not $Text -or -not $Text.Trim()) { Set-Status 'Пусто — нечего озвучивать'; return }
  if ($Provider) {
    $script:ActiveProvider = $Provider
  } else {
    $fallback = Resolve-Provider $Text
    if ($fallback) { Set-Status 'В тексте есть английские слова — озвучиваю через Яндекс' }
  }
  Stop-Speaking $false
  $chunks = @(Split-Text $Text ([int]$Cfg.maxCharsPerRequest))
  if (-not $chunks.Count) { Set-Status 'Пусто — нечего озвучивать'; return }
  $script:Session = [pscustomobject]@{ Chunks = $chunks; Files = @{}; Requested = 0; Played = 0; Source = $Source }
  Set-Status ("Готовлю озвучку… 0/{0}" -f $chunks.Count)
  Write-Log "speak ($Source): $($Text.Length) симв. в $($chunks.Count) куск(ах)"
  Request-More
}

function Stop-Speaking([bool]$ShowStatus = $true) {
  try { $script:Player.Stop(); $script:Player.Close() } catch { }
  $script:Speaking = $false
  $script:PendingPlay = $null
  $script:Session  = $null
  $script:Pending.Clear()
  if ($ShowStatus) { Set-Status 'Стоп' }
}

function Toggle-Pause {
  if (-not $script:Session) { return }
  if ($script:Speaking) {
    $script:Player.Pause()
    $script:Speaking = $false
    Set-Status 'Пауза'
  } else {
    $script:Speaking = $true
    $script:Player.Play()
    Set-Status ("Озвучиваю… {0}/{1}" -f ($script:Session.Played + 1), $script:Session.Chunks.Count)
  }
}

function Start-PendingPlay {
  if ($script:PendingPlay -and $script:PendingPlayAt -and ((Get-Date) - $script:PendingPlayAt).TotalMilliseconds -gt 1500) {
    $script:PendingPlay = $null
    try {
      $script:Player.Position = [TimeSpan]::Zero
      $script:Player.Play()
      Write-Log 'play started (fallback)'
    } catch { Write-Log "play fallback error: $($_.Exception.Message)" }
  }
}

function Remove-StaleSynthFiles {
  # подчищаем осиротевшие временные файлы синтеза
  if (-not $script:NextSweepAt -or (Get-Date) -gt $script:NextSweepAt) {
    $script:NextSweepAt = (Get-Date).AddMinutes(5)
    try {
      Get-ChildItem $CacheDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(edge|silero|sapi|voice)-' -and $_.LastWriteTime -lt (Get-Date).AddMinutes(-3) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
  }
}

function Read-SpoolQueue {
  try {
    $spooled = Get-ChildItem $SpoolDir -Filter '*.txt' -File | Sort-Object Name | Select-Object -First 1
    if ($spooled) {
      $content = [System.IO.File]::ReadAllText($spooled.FullName)
      Remove-Item $spooled.FullName -Force -ErrorAction SilentlyContinue
      if ($spooled.Name -match '-stop-') { Stop-Speaking }
      elseif ($content.Trim()) { Start-Speaking $content 'spool' }
    }
  } catch { }
}

function Complete-FileItem($item) {
  $outFile = $item.Req.OutFile
  # если синтез идёт в отдельном процессе — дожидаемся его выхода,
  # иначе файл ещё не дописан
  $hasProc = $false
  if ($item.Req -is [System.Collections.IDictionary]) { $hasProc = $item.Req.Contains('Proc') }
  else { $hasProc = ($item.Req.PSObject.Properties.Name -contains 'Proc') }
  if ($hasProc -and -not $item.Req.Proc.HasExited) { return }
  if (-not (Test-Path $outFile)) {
    # воркер сам сообщил об ошибке — не ждём таймаут
    $errFile = $null
    if ($item.Req -is [System.Collections.IDictionary]) { $errFile = $item.Req['ErrFile'] }
    else { $errFile = $item.Req.PSObject.Properties['ErrFile'].Value }
    if ($errFile -and (Test-Path $errFile)) {
      $script:Pending.Remove($item)
      $why = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
      Remove-Item $errFile, $item.Req.RequestFile -Force -ErrorAction SilentlyContinue
      Write-Log "file: ошибка воркера — $why"
      Invoke-ProviderFallback $item 'воркер вернул ошибку' "Движок не ответил: $why"
      return
    }
    # ждём файл, но не бесконечно
    if (((Get-Date) - $item.Requested).TotalSeconds -gt 40) {
      $script:Pending.Remove($item)
      Remove-Item $outFile, $item.Req.RequestFile -Force -ErrorAction SilentlyContinue
      Write-Log 'file: синтез не ответил'
      Invoke-ProviderFallback $item 'синтез не уложился в 40 секунд' 'Синтез не ответил за 40 секунд'
    }
    return
  }
  $script:Pending.Remove($item)
  try {
    Convert-WavToStandard $outFile $item.Path 0.5
    Remove-Item $outFile, $item.Req.RequestFile -Force -ErrorAction SilentlyContinue
    if ($script:Session) { $script:Session.Files[$item.Index] = $item.Path }
    Write-Log "chunk $($item.Index): $((Get-Item $item.Path).Length) байт ($($script:ActiveProvider))"
    Try-Play-Next
  } catch {
    Write-Log "file error: $($_.Exception.Message)"
    Invoke-ProviderFallback $item 'синтез не удался' "Ошибка разбора звука: $($_.Exception.Message)"
  }
}

function Complete-SileroItem($item) {
  if (-not (Test-Path $item.Req.PcmFile)) { return }
  $script:Pending.Remove($item)
  try {
    $bytes = [System.IO.File]::ReadAllBytes($item.Req.PcmFile)
    Remove-Item $item.Req.PcmFile, $item.Req.RequestFile -Force -ErrorAction SilentlyContinue
    if ($bytes.Length -lt 100) { throw 'пустой ответ Silero' }
    ConvertTo-WavFile -Pcm $bytes -Path $item.Path -SampleRate 48000
    if ($script:Session) { $script:Session.Files[$item.Index] = $item.Path }
    Write-Log "chunk $($item.Index): $($bytes.Length) байт (silero, $($Cfg.sileroSpeaker))"
    Try-Play-Next
  } catch {
    Write-Log "silero error: $($_.Exception.Message)"
    Invoke-ProviderFallback $item 'синтез не удался' "Ошибка Silero: $($_.Exception.Message)"
  }
}

function Complete-TaskItem($item) {
  if (-not $item.Task.IsCompleted) { return }
  $script:Pending.Remove($item)
  try {
    if ($item.Kind -eq 'pipe') {
      $bytes = $item.Pipe.Stream.ToArray()
      try { [void]$item.Pipe.Process.WaitForExit(5000) } catch { }
      ConvertTo-WavFile -Pcm $bytes -Path $item.Path -SampleRate $item.SampleRate
      if ($script:Session) { $script:Session.Files[$item.Index] = $item.Path }
      Write-Log "chunk $($item.Index): $($bytes.Length) байт (piper, $($Cfg.piperVoice))"
      Try-Play-Next
      return
    }
    $response = $item.Task.Result
    if ($response.IsSuccessStatusCode) {
      $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      # сервер может отдать несжатый звук: заворачиваем в wav по заголовку ответа
      $contentType = [string]$response.Content.Headers.ContentType
      if ($contentType -match 'pcm') {
        $rate = 48000
        if ($contentType -match 'rate=(\d+)') { $rate = [int]$Matches[1] }
        ConvertTo-WavFile -Pcm $bytes -Path $item.Path -SampleRate $rate
        Write-Log "chunk $($item.Index): $($bytes.Length) байт pcm ${rate} Гц -> wav"
      } elseif ((Get-ActiveProvider).WavFromRaw) {
        ConvertTo-WavFile -Pcm $bytes -Path $item.Path
      } else {
        [System.IO.File]::WriteAllBytes($item.Path, $bytes)
      }
      if ($script:Session) { $script:Session.Files[$item.Index] = $item.Path }
      Write-Log "chunk $($item.Index): $($bytes.Length) байт"
      Try-Play-Next
    } else {
      $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $message = Get-ErrorMessage $body
      # голос не знает такой роли эмоции — повторяем без неё
      if ($body -match 'role' -and $Cfg.yandexEmotion -and -not $script:YandexSkipEmotion) {
        $script:YandexSkipEmotion = $true
        Write-Log "yandex: голос не поддерживает эмоцию '$($Cfg.yandexEmotion)' — повторяю без неё"
        try {
          $retry = $script:Http.SendAsync((New-TtsRequest $item.Text))
          $script:Pending.Add([pscustomobject]@{ Index = $item.Index; Path = $item.Path; Task = $retry; Text = $item.Text })
          return
        } catch { }
      }
      Set-Status "Ошибка TTS: $message"
      Write-Log "tts error $([int]$response.StatusCode): $body"
      $script:Session = $null
      $script:Pending.Clear()
    }
  } catch {
    Set-Status "Ошибка TTS: $($_.Exception.Message)"
    Write-Log "tts exception: $($_.Exception.Message)"
    $script:Session = $null
    $script:Pending.Clear()
  }
}

function Complete-PendingItem($item) {
  switch ($item.Kind) {
    'file'   { Complete-FileItem $item }
    'silero' { Complete-SileroItem $item }
    default  { Complete-TaskItem $item }
  }
}

function Update-PendingQueue {
  foreach ($item in @($script:Pending)) { Complete-PendingItem $item }
}
