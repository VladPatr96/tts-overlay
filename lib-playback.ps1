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
  if ($Cfg.provider -eq 'yandex') { $parts += @($Cfg.yandexSpeed, $Cfg.yandexEmotion) }
  $parts += ($script:Pronounce | ConvertTo-Json -Compress -Depth 4)
  $payload = $parts -join '|'
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-', '').Substring(0, 8)
}

function Get-CachePath([string]$Text) {
  # ключ: движок+голос, формат, настройки произношения и сам текст
  $who = Get-ProviderKey
  if ($Cfg.provider -eq 'yandex') { $who += "|$($Cfg.yandexLang)" }
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
    if ($script:ActiveProvider -in @('piper', 'silero', 'edge', 'sapi')) {
      try {
        if ($script:ActiveProvider -eq 'silero') {
          $req = Start-SileroRequest $speech
          $script:Pending.Add([pscustomobject]@{ Index = $index; Path = $path; Kind = 'silero'; Req = $req })
        } elseif ($script:ActiveProvider -eq 'edge') {
          $ssml = ConvertTo-Ssml -Text $speech -Pronounce $script:Pronounce -EnglishAsEnglish ([bool]$Cfg.englishAsEnglish)
          $req = Start-EdgeRequest $ssml $true
          $script:Pending.Add([pscustomobject]@{ Index = $index; Path = $path; Kind = 'file'; Req = $req; Requested = (Get-Date) })
        } elseif ($script:ActiveProvider -eq 'sapi') {
          $req = Start-SapiRequest $speech
          $script:Pending.Add([pscustomobject]@{ Index = $index; Path = $path; Kind = 'file'; Req = $req; Requested = (Get-Date) })
        } else {
          $pipe = Start-LocalSynthesis $speech
          $script:Pending.Add([pscustomobject]@{
            Index = $index; Path = $path; Task = $pipe.Task; Kind = 'pipe'; Pipe = $pipe
            SampleRate = (Get-LocalSampleRate)
          })
        }
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
