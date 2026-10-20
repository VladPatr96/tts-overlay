# lib-stt.ps1 — диктовка: воркер распознавания, запись с микрофона, распознавание (OpenRouter или faster-whisper), результат в буфер.
# Подключается из tts-overlay.ps1 (dot-sourcing). Использует общее состояние главного скрипта: $Cfg, $script:SttWorker, $script:Voice, $script:Http, $script:OpenRouterKey, элементы окна.

function Start-SttWorker([bool]$Quiet = $false) {
  if ($script:SttWorker -and -not $script:SttWorker.HasExited) { return $true }
  try {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Cfg.sileroPython
    $info.Arguments = "`"$($Cfg.sttWorkerScript)`""
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.Environment['STT_MODEL'] = [string]$Cfg.sttWhisperModel
    $info.Environment['STT_LANG'] = [string]$Cfg.sttLang
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    # вывод воркера читаем в фоне: иначе канал забьётся и воркер встанет
    $null = $process.StandardOutput.ReadToEndAsync()
    $null = $process.StandardError.ReadToEndAsync()
    $script:SttWorker = $process
    Write-Log 'stt: воркер запущен'
    if (-not $Quiet) { Set-Status 'Распознавание: воркер запущен' }
    return $true
  } catch {
    Write-Log "stt: воркер не запустился ($($_.Exception.Message))"
    return $false
  }
}

function Send-SttCommand([string]$Command) {
  if (-not (Start-SttWorker $true)) { throw 'воркер распознавания не запущен' }
  $script:SttWorker.StandardInput.WriteLine($Command)
  $script:SttWorker.StandardInput.Flush()
}

function Get-SttCurrentModel {
  if ([string]$Cfg.sttProvider -eq 'whisper') { return [string]$Cfg.sttWhisperModel }
  return [string]$Cfg.sttModel
}

function Set-SttCurrentModel([string]$Value) {
  if ([string]$Cfg.sttProvider -eq 'whisper') { $Cfg.sttWhisperModel = $Value } else { $Cfg.sttModel = $Value }
}

function Remove-VoiceFiles {
  if (-not $script:Voice) { return }
  $path = $script:Voice.Path
  foreach ($suffix in @('', '.done', '.ok', '.txt', '.err')) {
    Remove-Item ($path + $suffix) -Force -ErrorAction SilentlyContinue
  }
}

function Fail-Voice([string]$Message) {
  Write-Log "voice: ошибка — $Message"
  Set-Status "Распознавание не удалось: $Message"
  Remove-VoiceFiles
  $script:Voice = $null
  $script:SttTask = $null
}

function Complete-Voice([string]$Text, [double]$Usd = 0.0) {
  if (-not $script:Voice) { return }
  $seconds = [double]$script:Voice.Seconds
  $text = ($Text -replace '\s+', ' ').Trim()
  if (-not $text) { Fail-Voice 'пустая расшифровка'; return }
  Write-Log ("voice: распознано ({0}): {1}" -f $Cfg.sttProvider, $text)
  Add-SttUsage $seconds $Usd
  $shown = if ($text.Length -gt 120) { $text.Substring(0, 120) + '…' } else { $text }
  if (Set-ClipboardText $text) { Set-Status "$shown  ·  скопировано в буфер" }
  else { Set-Status $shown }
  Remove-VoiceFiles
  $script:Voice = $null
  $script:SttTask = $null
}

function Start-VoiceRecording {
  if ($script:Voice) {
    # система повторяет WM_HOTKEY, пока клавиша нажата: молча игнорируем
    if ($script:Voice.State -ne 'recording') { Write-Log 'voice: предыдущая запись ещё обрабатывается' }
    return
  }
  if (-not (Start-SttWorker $true)) {
    Set-Status 'Распознавание: воркер не запустился'
    return
  }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $path = Join-Path $CacheDir "voice-$id.wav"
  $script:Voice = @{ State = 'recording'; Path = $path; Started = Get-Date; Stopped = Get-Date; Seconds = 0.0 }
  try {
    Send-SttCommand "rec|$path"
  } catch {
    Write-Log "voice: запись не началась ($($_.Exception.Message))"
    Set-Status "Запись не началась: $($_.Exception.Message)"
    $script:Voice = $null
    return
  }
  Set-Status 'Запись… отпустите клавишу'
  Write-Log 'voice: запись началась'
}

function Stop-VoiceRecording([string]$Reason = 'отпустили клавишу') {
  if (-not $script:Voice -or $script:Voice.State -ne 'recording') { return }
  try { Send-SttCommand 'stop' } catch { Write-Log "voice: stop не отправлен ($($_.Exception.Message))" }
  $script:Voice.State = 'stopping'
  $script:Voice.Stopped = Get-Date
  Write-Log "voice: запись остановлена ($Reason)"
}

function Start-VoiceRecognition {
  if (-not $script:Voice) { return }
  $path = $script:Voice.Path
  if ([string]$Cfg.sttProvider -eq 'whisper') {
    try {
      Send-SttCommand "stt|$path"
      $script:Voice.State = 'transcribing'
      Set-Status 'Распознаю локально…'
      Write-Log "voice: локальное распознавание, модель $($Cfg.sttWhisperModel), файл $path"
    } catch {
      Fail-Voice $_.Exception.Message
    }
    return
  }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $b64 = [Convert]::ToBase64String($bytes)
    $payload = [ordered]@{
      model = [string]$Cfg.sttModel
      messages = @(
        [ordered]@{
          role = 'user'
          content = @(
            [ordered]@{ type = 'text'; text = [string]$Cfg.sttPrompt }
            [ordered]@{ type = 'input_audio'; input_audio = [ordered]@{ data = $b64; format = 'wav' } }
          )
        }
      )
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 8
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://openrouter.ai/api/v1/chat/completions')
    $request.Content = $content
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:OpenRouterKey)
    $script:SttTask = $script:Http.SendAsync($request)
    $script:Voice.State = 'transcribing'
    Set-Status 'Распознаю в облаке…'
    Write-Log "voice: запрос к OpenRouter, модель $($Cfg.sttModel), файл $path"
  } catch {
    Fail-Voice $_.Exception.Message
  }
}

function Update-VoiceState {
  # вызывается из тика таймера: ловит отпускание клавиши и забирает результат
  if (-not $script:Voice) { return }
  $voice = $script:Voice
  if ($voice.State -eq 'recording') {
    $down = ([TtsHotkey]::GetAsyncKeyState($script:VoiceKeyVk) -band 0x8000) -ne 0
    $elapsed = ((Get-Date) - $voice.Started).TotalSeconds
    if (-not $down) {
      Stop-VoiceRecording 'отпустили клавишу'
    } elseif ($elapsed -ge [double]$Cfg.sttMaxSeconds) {
      Stop-VoiceRecording "лимит $($Cfg.sttMaxSeconds) с"
      Set-Status "Запись остановлена: лимит $($Cfg.sttMaxSeconds) с"
    }
    return
  }
  if ($voice.State -eq 'stopping') {
    $done = $voice.Path + '.done'
    $err = $voice.Path + '.err'
    if (Test-Path $done) {
      try { $voice.Seconds = [double](Get-Content $done -Raw) } catch { $voice.Seconds = 0.0 }
      Remove-Item $done -Force -ErrorAction SilentlyContinue
      Write-Log ("voice: записано {0:N1} с" -f $voice.Seconds)
      if ($voice.Seconds -lt 0.3) { Fail-Voice 'запись слишком короткая'; return }
      Start-VoiceRecognition
    } elseif (Test-Path $err) {
      Fail-Voice ((Get-Content $err -Raw -Encoding utf8 -ErrorAction SilentlyContinue) -replace '\s+', ' ')
    } elseif (((Get-Date) - $voice.Stopped).TotalSeconds -gt 30) {
      Fail-Voice 'воркер не отдал запись'
    }
    return
  }
  if ($voice.State -eq 'transcribing') {
    if ([string]$Cfg.sttProvider -eq 'whisper') {
      $ok = $voice.Path + '.ok'
      $err = $voice.Path + '.err'
      if (Test-Path $ok) {
        $text = Get-Content $ok -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        Complete-Voice $text 0.0
      } elseif (Test-Path $err) {
        Fail-Voice ((Get-Content $err -Raw -Encoding utf8 -ErrorAction SilentlyContinue) -replace '\s+', ' ')
      } elseif (((Get-Date) - $voice.Stopped).TotalSeconds -gt 300) {
        Fail-Voice 'локальное распознавание не закончилось'
      }
      return
    }
    if (-not $script:SttTask) { return }
    if ($script:SttTask.IsCompleted) {
      $task = $script:SttTask
      $script:SttTask = $null
      try {
        $response = $task.Result
        if ($response.IsSuccessStatusCode) {
          $parsed = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
          $text = $parsed.choices[0].message.content
          if ($text -is [array]) { $text = (($text | ForEach-Object { $_.text }) -join '') }
          $usd = 0.0
          if ($parsed.usage -and $parsed.usage.cost) { $usd = [double]$parsed.usage.cost }
          Complete-Voice ([string]$text) $usd
        } else {
          $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          Fail-Voice (Get-ErrorMessage $body)
        }
      } catch {
        Fail-Voice $_.Exception.Message
      }
    } elseif (((Get-Date) - $voice.Stopped).TotalSeconds -gt 180) {
      Fail-Voice 'облако не ответило'
    }
  }
}
