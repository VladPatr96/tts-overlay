# lib-input.ps1 — ввод: горячие клавиши, перехват выделенного текста, буфер обмена.
# Подключается из tts-overlay.ps1 (dot-sourcing). Использует общее состояние главного скрипта: $Cfg, $script:HotkeyMods, $script:HotkeySeen, $script:Hwnd, $script:Selection, класс TtsHotkey (Add-Type в главном скрипте).

function Send-CtrlKey([byte]$Key) {
  # настоящая инъекция клавиш через системную очередь: SendKeys современные
  # приложения (Chrome, Electron, WinUI) игнорируют, а это работает везде.
  # между нажатиями нужны паузы, иначе часть приложений не успевает
  # увидеть состояние модификатора и Ctrl+C до них не доходит
  $ctrl = [byte]0x11
  $scanCtrl = [byte][TtsHotkey]::MapVirtualKey($ctrl, 0)
  $scanKey  = [byte][TtsHotkey]::MapVirtualKey($Key, 0)
  [TtsHotkey]::keybd_event($ctrl, $scanCtrl, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [TtsHotkey]::keybd_event($Key, $scanKey, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [TtsHotkey]::keybd_event($Key, $scanKey, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [TtsHotkey]::keybd_event($ctrl, $scanCtrl, 2, [UIntPtr]::Zero)
}

function Wait-ModifiersReleased([int]$TimeoutMs = 800) {
  # хоткей нажимают, когда Ctrl и Alt ещё зажаты; если скопировать сейчас,
  # C уйдёт как Ctrl+Alt+C и выделение не скопируется
  $start = Get-Date
  $deadline = $start.AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $ctrl = ([TtsHotkey]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $alt  = ([TtsHotkey]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
    $shift = ([TtsHotkey]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
    if (-not $ctrl -and -not $alt -and -not $shift) { break }
    Start-Sleep -Milliseconds 25
  }
  return [int]((Get-Date) - $start).TotalMilliseconds
}

function Get-WindowTitle([IntPtr]$Handle) {
  if ($Handle -eq [IntPtr]::Zero) { return '' }
  $sb = New-Object System.Text.StringBuilder 256
  [void][TtsHotkey]::GetWindowText($Handle, $sb, 256)
  return $sb.ToString()
}

function Get-SelectedTextViaUia {
  # запасной путь: спросить выделение напрямую у элемента в фокусе,
  # не трогая буфер обмена (работает в браузерах, редакторах, Electron)
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if (-not $focused) { return '' }
    $pattern = $focused.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $ranges = @($pattern.GetSelection())
    if (-not $ranges.Count) { return '' }
    $text = (($ranges | ForEach-Object { $_.GetText(-1) }) -join '')
    if ($text.Trim()) { Write-Log "uia: выделено $($text.Length) симв. в '$($focused.Current.Name)'"; return $text }
  } catch { Write-Log "uia: не вышло ($($_.Exception.Message))" }
  return ''
}

function Get-SelectedText {
  $waited = Wait-ModifiersReleased
  $before = [TtsHotkey]::GetClipboardSequenceNumber()
  $previous = ''
  try { $previous = [System.Windows.Forms.Clipboard]::GetText() } catch { }
  $where = Get-WindowTitle ([TtsHotkey]::GetForegroundWindow())
  Send-CtrlKey 0x43
  Start-Sleep -Milliseconds 260
  $after = [TtsHotkey]::GetClipboardSequenceNumber()
  Write-Log ("clipboard: окно '$where', ждали $waited мс, seq $before -> $after, было $($previous.Length) симв.")
  if ($after -ne $before) {
    $text = ''
    try { $text = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    # возвращаем в буфер то, что там было до нас
    if ($previous -and $previous -ne $text) {
      try { [System.Windows.Forms.Clipboard]::SetText($previous) } catch { }
    }
    if ($text.Trim()) { return $text }
  }
  # копирование не сработало — пробуем выделение через UI Automation
  return (Get-SelectedTextViaUia)
}

function Speak-Selection {
  # если фокус и так в чужой программе — ничего не трогаем, Ctrl+C уйдёт туда
  $foreground = [TtsHotkey]::GetForegroundWindow()
  if ($foreground -eq [IntPtr]::Zero -or $foreground -eq $script:Hwnd) {
    if ($script:LastForeground -ne [IntPtr]::Zero) {
      [void][TtsHotkey]::SetForegroundWindow($script:LastForeground)
      Start-Sleep -Milliseconds 180
    }
  }
  $targetTitle = Get-WindowTitle ([TtsHotkey]::GetForegroundWindow())
  $text = Get-SelectedText
  $head = if ($text.Length -gt 70) { $text.Substring(0, 70) } else { $text }
  $tail = if ($text.Length -gt 40) { $text.Substring($text.Length - 40) } else { '' }
  Write-Log ("speak-selection: окно '$targetTitle', перехвачено $($text.Length) симв. | начало: " + ($head -replace '\s+', ' ') + " | конец: " + ($tail -replace '\s+', ' '))
  $script:Selection = @{ chars = $text.Length }
  $null = Resolve-Provider $text
  Update-SelInfo
  if (-not $text.Trim()) { Set-Status 'Ничего не выделено'; return }
  Start-Speaking $text 'выделенное'
}

function Speak-Clipboard {
  $text = ''
  try { $text = [System.Windows.Forms.Clipboard]::GetText() } catch { }
  Write-Log "speak-clipboard: $($text.Length) симв."
  $script:Selection = @{ chars = $text.Length }
  $null = Resolve-Provider $text
  Update-SelInfo
  if (-not $text.Trim()) { Set-Status 'Буфер пуст'; return }
  Start-Speaking $text 'буфер'
}

function Convert-Hotkey([string]$Spec) {
  $mods = 0
  $key = $null
  foreach ($part in ($Spec -split '\+')) {
    $token = $part.Trim().ToLowerInvariant()
    if ($script:HotkeyMods.ContainsKey($token)) { $mods = $mods -bor $script:HotkeyMods[$token] } else { $key = $token }
  }
  if (-not $key) { return $null }
  $vk = if ($key -eq 'space') { 0x20 }
        elseif ($key -match '^f(\d{1,2})$') { 0x6F + [int]$Matches[1] }
        else { [int][char]($key.ToUpperInvariant()) }
  return @{ Mods = $mods; Vk = $vk }
}

function Register-Hotkeys {
  $specs = @{ 1 = $Cfg.speakSelectionHotkey; 2 = $Cfg.speakClipboardHotkey; 3 = $Cfg.stopHotkey; 4 = $Cfg.sttHotkey }
  $ok = @()
  foreach ($id in $specs.Keys) {
    $parsed = Convert-Hotkey $specs[$id]
    if (-not $parsed) { continue }
    if ([TtsHotkey]::RegisterHotKey($script:Hwnd, $id, $parsed.Mods, $parsed.Vk)) {
      $ok += $specs[$id]
      # главная клавиша нужна, чтобы поймать отпускание: события «клавиша отпущена» в Windows нет
      if ($id -eq 4) { $script:VoiceKeyVk = $parsed.Vk }
    } else {
      Write-Log "hotkey: не зарегистрировал $($specs[$id])"
    }
  }
  Write-Log "hotkeys: $($ok -join ', ')"
  return $ok
}

function Set-ClipboardText([string]$Text) {
  if (-not $Text) { return $false }
  for ($i = 0; $i -lt 5; $i++) {
    try { [System.Windows.Forms.Clipboard]::SetText($Text); return $true }
    catch { Start-Sleep -Milliseconds 120 }
  }
  return $false
}
