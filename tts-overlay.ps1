#requires -version 7.0
<#
  tts-overlay.ps1 — плавающий оверлей поверх всех окон: озвучивает выделенный текст
  и буфер обмена через OpenRouter TTS (POST /api/v1/audio/speech).

  Обычный запуск (оверлей живёт в трее):
      pwsh -NoProfile -WindowStyle Hidden -File tts-overlay.ps1

  Разовая команда по уже запущенному оверлею (через папку spool):
      pwsh -File tts-overlay.ps1 -Say "текст"
      pwsh -File tts-overlay.ps1 -Clipboard
      pwsh -File tts-overlay.ps1 -Stop

  Горячие клавиши по умолчанию: Ctrl+Alt+S — выделенное, Ctrl+Alt+D — буфер, Ctrl+Alt+X — стоп.
#>
param(
  [string]$Say,
  [switch]$Clipboard,
  [switch]$Stop,
  [switch]$Start
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TtsRoot = $Root
# модули по слоям (ADR 0001): только функции, общее состояние — в этом скрипте
foreach ($lib in 'lib-core', 'lib-usage', 'lib-providers', 'lib-playback', 'lib-input', 'lib-stt', 'lib-text') { . (Join-Path $Root "$lib.ps1") }
$ConfigPath = Join-Path $Root 'config.json'
$CacheDir   = Join-Path $Root 'cache'
$SpoolDir   = Join-Path $Root 'spool'
$LogPath    = Join-Path $Root 'tts-overlay.log'
$ApiUrl     = 'https://openrouter.ai/api/v1/audio/speech'
$ModelsUrl  = 'https://openrouter.ai/api/v1/models?output_modalities=speech'
$YandexTtsUrl = 'https://tts.api.cloud.yandex.net/speech/v1/tts:synthesize'

foreach ($dir in @($CacheDir, $SpoolDir)) {
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ---------------------------------------------------------------- разовая команда

function Push-Spool([string]$Text, [string]$Kind) {
  if (-not $Text.Trim()) { Write-Log 'spool: пустой текст, пропуск'; return }
  $file = Join-Path $SpoolDir ('{0}-{1}-{2}.txt' -f (Get-Date -Format 'HHmmssfff'), $Kind, ([guid]::NewGuid().ToString('N').Substring(0, 6)))
  [System.IO.File]::WriteAllText($file, $Text, [System.Text.UTF8Encoding]::new($false))
  Write-Log "spool: положено $file ($($Text.Length) симв.)"
}

if ($Say)       { Push-Spool $Say 'say';   exit 0 }
if ($Stop)      { Push-Spool 'stop' 'stop'; exit 0 }
if ($Clipboard -and -not $Start) {
  Add-Type -AssemblyName System.Windows.Forms
  Push-Spool ([System.Windows.Forms.Clipboard]::GetText()) 'clip'
  exit 0
}

# ---------------------------------------------------------------- конфиг
$Cfg = Import-Config

if (-not (Test-Path $ConfigPath)) { Save-Config }

# словарь произношения: создаём с базовыми записями, если его ещё нет
Save-DefaultPronounce
$script:Pronounce = Get-PronounceMap
Write-Log "словарь произношения: $($script:Pronounce.Count) записей"

# ---------------------------------------------------------------- WPF и Win32

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes } catch { Write-Log "uia: библиотеки не загрузились ($($_.Exception.Message))" }

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TtsHotkey {
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
}
'@

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Озвучка" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="Height"
        Width="390" WindowStartupLocation="Manual" ShowActivated="False"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Tb" TargetType="Button">
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="Foreground" Value="#F2FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#33FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#4DFFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#B3FFFFFF"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,6,8,2"/>
    </Style>

    <Style x:Key="CbItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F2FFFFFF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Margin="4,1" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="b" Property="Background" Value="#33FFFFFF"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#4D7C5CFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Cb" TargetType="ComboBox">
      <Setter Property="Foreground" Value="#F2FFFFFF"/>
      <Setter Property="Background" Value="#26FFFFFF"/>
      <Setter Property="BorderBrush" Value="#33FFFFFF"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="MinHeight" Value="28"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource CbItem}"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid x:Name="Root">
              <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" Background="#26FFFFFF" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="8"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="10,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
              <Path Data="M 0 0 L 4 4 L 8 0" Stroke="#B3FFFFFF" StrokeThickness="1.4"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                     PopupAnimation="Fade" IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border Background="#F514141A" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="10"
                        Margin="0,4,0,0" Padding="0,4" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <ScrollViewer MaxHeight="280" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="#F01A1A20" CornerRadius="14" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="12">
    <StackPanel>
      <Grid x:Name="TitleBar" Background="Transparent" Margin="0,0,0,6">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Озвучка" Foreground="#F2FFFFFF" FontWeight="SemiBold" FontSize="14" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" x:Name="HotkeyHint" Text="" Foreground="#80FFFFFF" FontSize="10" Margin="10,2,0,0" VerticalAlignment="Center"/>
        <Button Grid.Column="2" x:Name="BtnHide" Content="✕" Style="{StaticResource Tb}" Padding="8,2" Margin="0" ToolTip="Свернуть в трей"/>
      </Grid>

      <TextBlock x:Name="Status" Text="Выдели текст и нажми Ctrl+Alt+S" Foreground="#E6FFFFFF" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8"/>

      <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
        <Button x:Name="BtnSpeak" Content="▶  Озвучить" Style="{StaticResource Tb}" ToolTip="Озвучить выделенное"/>
        <Button x:Name="BtnClip"  Content="⧉  Буфер"   Style="{StaticResource Tb}" ToolTip="Озвучить буфер обмена"/>
        <Button x:Name="BtnPause" Content="⏸"          Style="{StaticResource Tb}" ToolTip="Пауза / продолжить"/>
        <Button x:Name="BtnStop"  Content="⏹"          Style="{StaticResource Tb}" ToolTip="Стоп"/>
        <Button x:Name="BtnGear"  Content="⚙"          Style="{StaticResource Tb}" Margin="0" ToolTip="Настройки"/>
      </StackPanel>

      <TextBlock x:Name="CostLine" Foreground="#99FFFFFF" FontSize="10" TextWrapping="Wrap" Margin="0,2,0,0"/>
      <TextBlock x:Name="SelInfo" Foreground="#80FFFFFF" FontSize="10" TextWrapping="Wrap" Margin="0,1,0,0"/>

      <StackPanel x:Name="Settings" Visibility="Collapsed" Margin="0,6,0,0">
        <TextBlock Text="Источник" Style="{StaticResource Lbl}"/>
        <ComboBox x:Name="ProviderCombo" Style="{StaticResource Cb}"/>
        <StackPanel x:Name="ModelBlock">
          <TextBlock Text="Модель" Style="{StaticResource Lbl}"/>
          <ComboBox x:Name="ModelCombo" Style="{StaticResource Cb}"/>
        </StackPanel>
        <TextBlock Text="Голос" Style="{StaticResource Lbl}"/>
        <ComboBox x:Name="VoiceCombo" Style="{StaticResource Cb}"/>
        <TextBlock Text="Распознавание речи" Style="{StaticResource Lbl}"/>
        <ComboBox x:Name="SttProviderCombo" Style="{StaticResource Cb}"/>
        <TextBlock Text="Модель распознавания" Style="{StaticResource Lbl}"/>
        <TextBox x:Name="SttModelBox" Background="#26FFFFFF" Foreground="#F2FFFFFF" BorderBrush="#33FFFFFF"
                 CaretBrush="#F2FFFFFF" BorderThickness="1" Padding="8,5" FontSize="12" Margin="0,0,0,4"/>
        <CheckBox x:Name="ChkNumbers" Foreground="#B3FFFFFF" FontSize="11" Margin="0,6,0,0" Content="Читать числа и даты словами" />
        <CheckBox x:Name="ChkEnglish" Foreground="#B3FFFFFF" FontSize="11" Margin="0,2,0,0" Content="Английские слова по-английски" />
        <Button x:Name="BtnDict" Content="Словарь произношения" Style="{StaticResource Tb}" Margin="0,6,0,0" ToolTip="Открыть файл pronounce.json" />
        <TextBlock Text="Скорость" Style="{StaticResource Lbl}"/>
        <StackPanel Orientation="Horizontal">
          <ComboBox x:Name="SpeedCombo" Width="90" Style="{StaticResource Cb}"/>
          <Button x:Name="BtnTest" Content="Проверить" Style="{StaticResource Tb}" Margin="10,0,0,0"/>
          <Button x:Name="BtnReload" Content="Обновить список" Style="{StaticResource Tb}" Margin="6,0,0,0"/>
        </StackPanel>
        <TextBlock x:Name="ModelInfo" Foreground="#80FFFFFF" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"/>
        <TextBlock Text="Затраты" Style="{StaticResource Lbl}"/>
        <TextBlock x:Name="CostDetails" Foreground="#B3FFFFFF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,6"/>
        <Button x:Name="BtnRefreshCost" Content="Обновить баланс" Style="{StaticResource Tb}" Margin="0"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$win = [System.Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in 'TitleBar','HotkeyHint','BtnHide','Status','BtnSpeak','BtnClip','BtnPause','BtnStop','BtnGear','Settings','ProviderCombo','ModelBlock','ModelCombo','VoiceCombo','SpeedCombo','BtnTest','BtnReload','ModelInfo','CostLine','SelInfo','CostDetails','BtnRefreshCost','ChkNumbers','ChkEnglish','BtnDict','SttProviderCombo','SttModelBox') {
  Set-Variable -Name "ui$name" -Value $win.FindName($name) -Scope Script
}

# ---------------------------------------------------------------- состояние

$script:Http = [System.Net.Http.HttpClient]::new()
$script:Http.Timeout = [TimeSpan]::FromSeconds(120)
$script:Http.DefaultRequestHeaders.Add('HTTP-Referer', 'https://opencode.ai/')
$script:Http.DefaultRequestHeaders.Add('X-Title', 'tts-overlay')
$script:OpenRouterKey = ''
try { $script:OpenRouterKey = Get-ApiKey } catch { Write-Log "ключ OpenRouter: $($_.Exception.Message)" }

# голоса Яндекс SpeechKit, доступные на ключе (v1 API)
$script:YandexVoices = [ordered]@{
  'alena'   = 'Алёна — женский'
  'jane'    = 'Джейн — женский'
  'omazh'   = 'Омаж — женский'
  'marina'  = 'Марина — женский'
  'filipp'  = 'Филипп — мужской'
  'ermil'   = 'Ермил — мужской'
  'zahar'   = 'Захар — мужской'
  'madirus' = 'Мадирус — мужской'
}

$script:Player   = [System.Windows.Media.MediaPlayer]::new()
$script:Player.Volume = 1.0
$script:Session  = $null      # @{ Chunks=[string[]]; Files=@{}; Requested; Played; Source }
$script:Pending  = [System.Collections.Generic.List[object]]::new()
$script:Speaking = $false
$script:PendingPlay = $null
$script:PlayStartedAt = $null
$script:Hwnd     = [IntPtr]::Zero
$script:LastForeground = [IntPtr]::Zero
$script:ModelTask = $null
$script:Models   = @()
$script:Voices   = @()
$script:BalanceTask = $null
$script:RateTask = $null
$script:NextBalanceAt = $null
$script:Selection = $null
$script:SileroWorker = $null
$script:YandexSkipEmotion = $false
$script:SileroModelLoaded = ''
$script:EdgeWorker = $null
$script:Providers = Get-ProviderMap
$script:FallbackProviderId = 'yandex'   # запасной движок: озвучивает, когда основной не ответил
$script:ActiveProvider = [string]$Cfg.provider
# ---------------------------------------------------------------- учёт затрат

$UsagePath = Join-Path $Root 'usage.json'

Import-Usage

$script:HotkeySeen = @{}
$script:QueueSelection = $null
$script:QueueClipboard = $null

function Set-Status([string]$Text) {
  try { $uiStatus.Text = $Text } catch { }
}

# ---------------------------------------------------------------- текст и кэш

# --- Silero: постоянный воркер, модель грузится один раз ---

# ---------------------------------------------------------------- запрос к TTS

# ---------------------------------------------------------------- выделенное и буфер

# ---------------------------------------------------------------- список моделей и голосов

function Apply-Models {
  $models = @($script:Models)
  $uiModelCombo.Items.Clear()
  $index = 0
  $selected = 0
  foreach ($model in $models) {
    $price = if ($model.pricing -and [double]$model.pricing.prompt -ne 0) { '$' + ([double]$model.pricing.prompt * 1000).ToString('0.#####') + ' / 1k симв.' } else { 'бесплатно' }
    [void]$uiModelCombo.Items.Add(('{0} — {1}' -f $model.name, $price))
    if ($model.id -eq $Cfg.model) { $selected = $index }
    $index++
  }
  if ($uiModelCombo.Items.Count) {
    $uiModelCombo.SelectedIndex = $selected
    $script:Voices = @($models[$selected].supported_voices)
    Apply-Voices
    $uiModelInfo.Text = "Модель: $($models[$selected].id)"
  }
}

function Apply-Voices {
  $uiVoiceCombo.Items.Clear()
  $provider = Get-ConfiguredProvider
  if ($provider.Voices) {
    $uiVoiceCombo.ToolTip = $provider.Tooltip
    $script:Voices = @(& $provider.Voices)
    $titles = if ($provider.VoiceTitles) { & $provider.VoiceTitles } else { $null }
    foreach ($name in $script:Voices) {
      [void]$uiVoiceCombo.Items.Add($(if ($titles) { '{0} — {1}' -f $name, $titles[$name] } else { $name }))
    }
    $index = [Array]::IndexOf($script:Voices, [string]$Cfg.($provider.VoiceKey))
    if ($index -lt 0) {
      $index = 0
      $Cfg.($provider.VoiceKey) = [string]$script:Voices[0]
      Save-Config
    }
    $uiVoiceCombo.SelectedIndex = $index
    $uiModelInfo.Text = if ($provider.Free) { "$(Get-ProviderLabel) · бесплатно" } else { & $provider.Info }
    return
  }

  if (-not $script:Voices.Count) { $script:Voices = @(Get-VoiceFallback $Cfg.model) }
  if (-not $script:Voices.Count) {
    # список моделей ещё не загружен — голос не трогаем и конфиг не переписываем
    [void]$uiVoiceCombo.Items.Add('(по умолчанию)')
    $uiVoiceCombo.SelectedIndex = 0
    $uiVoiceCombo.ToolTip = 'У этой модели нет списка голосов — звучит голосом по умолчанию.'
    return
  }
  $uiVoiceCombo.ToolTip = 'Голос из списка модели.'
  foreach ($voice in $script:Voices) { [void]$uiVoiceCombo.Items.Add($voice) }
  $index = [Array]::IndexOf($script:Voices, $Cfg.voice)
  if ($index -lt 0) {
    $index = 0
    $Cfg.voice = [string]$script:Voices[0]
    Save-Config
  }
  $uiVoiceCombo.SelectedIndex = $index
}

function Apply-Provider {
  $script:ActiveProvider = [string]$Cfg.provider
  $hasModels = (Get-ConfiguredProvider).HasModels
  $uiModelBlock.Visibility = if ($hasModels) { 'Visible' } else { 'Collapsed' }
  $uiBtnReload.IsEnabled = $hasModels
  Apply-Voices
  if ($hasModels -and -not $script:Models.Count) { Load-Models }
  Update-CostLine
  Update-SelInfo
}

# ---------------------------------------------------------------- горячие клавиши

$script:HotkeyMods = @{ ctrl = 2; alt = 1; shift = 4; win = 8 }

# ---------------------------------------------------------------- распознавание речи

$script:SttWorker = $null
$script:Voice = $null
$script:SttTask = $null
$script:VoiceKeyVk = 0x56

# ---------------------------------------------------------------- события интерфейса

$uiBtnHide.Add_Click({
  Save-Config
  $win.Hide()
})

$uiBtnSpeak.Add_Click({ Speak-Selection })
$uiBtnClip.Add_Click({ Speak-Clipboard })
$uiBtnStop.Add_Click({ Stop-Speaking })
$uiBtnPause.Add_Click({ Toggle-Pause })
$uiBtnTest.Add_Click({
  Start-Speaking 'Проверка голоса. Так будет звучать озвученный текст в этом оверлее.' 'проверка'
})
$uiBtnReload.Add_Click({ Load-Models })
$uiBtnRefreshCost.Add_Click({
  Refresh-Balance
  Refresh-Rate
  Update-CostLine
})
$uiBtnGear.Add_Click({
  $uiSettings.Visibility = if ($uiSettings.Visibility -eq 'Collapsed') { 'Visible' } else { 'Collapsed' }
  if ($uiSettings.Visibility -eq 'Visible' -and (Get-ConfiguredProvider).HasModels -and -not $uiModelCombo.Items.Count) { Load-Models }
})

$uiTitleBar.Add_MouseLeftButtonDown({
  try { $win.DragMove() } catch { }
})

$uiModelCombo.Add_SelectionChanged({
  if ($uiModelCombo.SelectedIndex -lt 0 -or $uiModelCombo.SelectedIndex -ge $script:Models.Count) { return }
  if (-not (Get-ConfiguredProvider).HasModels) { return }
  $model = $script:Models[$uiModelCombo.SelectedIndex]
  $Cfg.model = $model.id
  $script:Voices = @($model.supported_voices)
  Apply-Voices
  $uiModelInfo.Text = "Модель: $($model.id)"
  Save-Config
})

$uiProviderCombo.Add_SelectionChanged({
  if ($uiProviderCombo.SelectedIndex -lt 0) { return }
  $Cfg.provider = [string]@($script:Providers.Keys)[$uiProviderCombo.SelectedIndex]
  Save-Config
  Apply-Provider
})

$uiVoiceCombo.Add_SelectionChanged({
  if ($uiVoiceCombo.SelectedIndex -lt 0 -or $uiVoiceCombo.SelectedIndex -ge $script:Voices.Count) { return }
  $provider = Get-ConfiguredProvider
  $Cfg.($provider.VoiceKey) = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
  if ($provider.Info) { $uiModelInfo.Text = & $provider.Info }
  Save-Config
  Update-CostLine
  Update-SelInfo
})

$uiChkNumbers.Add_Click({
  $Cfg.readNumbers = [bool]$uiChkNumbers.IsChecked
  Save-Config
  Update-CostLine
})
$uiSttProviderCombo.Add_SelectionChanged({
  if ($uiSttProviderCombo.SelectedIndex -lt 0) { return }
  $Cfg.sttProvider = [string]$script:SttProviders[$uiSttProviderCombo.SelectedIndex]
  $uiSttModelBox.Text = Get-SttCurrentModel
  Save-Config
  Write-Log "stt: движок распознавания — $($Cfg.sttProvider)"
})
$uiSttModelBox.Add_LostKeyboardFocus({
  $value = $uiSttModelBox.Text.Trim()
  if ($value) {
    Set-SttCurrentModel $value
    Save-Config
  }
})
$uiChkEnglish.Add_Click({
  $Cfg.englishAsEnglish = [bool]$uiChkEnglish.IsChecked
  Save-Config
})
$uiBtnDict.Add_Click({
  $path = Join-Path $Root 'pronounce.json'
  if (-not (Test-Path $path)) { Save-DefaultPronounce }
  Start-Process notepad.exe -ArgumentList $path
})
$uiSpeedCombo.Add_SelectionChanged({
  if ($uiSpeedCombo.SelectedIndex -lt 0 -or $uiSpeedCombo.SelectedIndex -ge $speedChoices.Count) { return }
  $Cfg.speed = [double]$speedChoices[$uiSpeedCombo.SelectedIndex]
  Save-Config
})

$script:Player.Add_MediaOpened({
  if ($script:PendingPlay) {
    $script:PendingPlay = $null
    try {
      $script:PlayStartedAt = Get-Date
      $script:Player.Play()
      $dur = if ($script:Player.NaturalDuration.HasTimeSpan) { [Math]::Round($script:Player.NaturalDuration.TimeSpan.TotalSeconds, 2) } else { '?' }
      Write-Log ("play started: длительность {0} с, позиция {1:N2}, скорость {2}" -f $dur, $script:Player.Position.TotalSeconds, $script:Player.SpeedRatio)
    } catch { Write-Log "play error: $($_.Exception.Message)" }
  }
})

$script:Player.Add_MediaEnded({
  if (-not $script:Session) { return }
  $played = if ($script:PlayStartedAt) { [Math]::Round(((Get-Date) - $script:PlayStartedAt).TotalSeconds, 2) } else { '?' }
  Write-Log ("ended {0}/{1} (играло {2} с)" -f ($script:Session.Played + 1), $script:Session.Chunks.Count, $played)
  $script:Session.Played++
  $script:Speaking = $false
  if ($script:Session.Played -ge $script:Session.Chunks.Count) {
    Set-Status 'Готово'
    $script:Session = $null
    Clear-CacheIfNeeded
  } else {
    Try-Play-Next
    Request-More
  }
})

$script:Player.Add_MediaFailed({
  param($sender, $args)
  $detail = "$($args.ErrorException.GetType().Name): $($args.ErrorException.Message)"
  Write-Log "media failed: $detail"
  Set-Status 'Нет звука: проверь устройство вывода в Windows (Параметры → Звук)'
  $script:Speaking = $false
  if ($script:Session) {
    $script:Session.Played++
    if ($script:Session.Played -lt $script:Session.Chunks.Count) { Try-Play-Next }
    else { $script:Session = $null }
  }
})

# ---------------------------------------------------------------- таймер: задачи, spool, позиция

$script:Timer = [System.Windows.Threading.DispatcherTimer]::new()
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:Timer.Add_Tick({
  Update-VoiceState

  if ($script:QueueSelection -and [DateTime]::UtcNow -ge $script:QueueSelection) {
    $script:QueueSelection = $null
    Speak-Selection
  }
  if ($script:QueueClipboard -and [DateTime]::UtcNow -ge $script:QueueClipboard) {
    $script:QueueClipboard = $null
    Speak-Clipboard
  }

  $foreground = [TtsHotkey]::GetForegroundWindow()
  if ($foreground -ne [IntPtr]::Zero -and $foreground -ne $script:Hwnd) { $script:LastForeground = $foreground }

  if ($script:PendingPlay -and $script:PendingPlayAt -and ((Get-Date) - $script:PendingPlayAt).TotalMilliseconds -gt 1500) {
    $script:PendingPlay = $null
    try {
      $script:Player.Position = [TimeSpan]::Zero
      $script:Player.Play()
      Write-Log 'play started (fallback)'
    } catch { Write-Log "play fallback error: $($_.Exception.Message)" }
  }

  if ($script:BalanceTask -and $script:BalanceTask.IsCompleted) {
    $task = $script:BalanceTask
    $script:BalanceTask = $null
    try {
      $response = $task.Result
      if ($response.IsSuccessStatusCode) {
        $parsed = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $balance = $script:Usage.balance.openrouter
        $balance.total = [double]$parsed.data.total_credits
        $balance.used  = [double]$parsed.data.total_usage
        $balance.left  = [double]$parsed.data.total_credits - [double]$parsed.data.total_usage
        $balance.at    = Get-Date -Format 'dd.MM HH:mm'
        Save-Usage
        Update-CostLine
      }
    } catch { Write-Log "balance: ошибка $($_.Exception.Message)" }
  }

  if ($script:RateTask -and $script:RateTask.IsCompleted) {
    $task = $script:RateTask
    $script:RateTask = $null
    try {
      $response = $task.Result
      if ($response.IsSuccessStatusCode) {
        $parsed = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $usd = $parsed.Valute.USD
        if (-not $usd) {
          $usd = @($parsed.Valute.PSObject.Properties.Value) | Where-Object { $_.CharCode -eq 'USD' } | Select-Object -First 1
        }
        if ($usd) {
          $script:Usage.rate.usdRub = [double]$usd.Value
          try {
            $rateDate = $parsed.Date
            if ($rateDate -is [datetime]) { $script:Usage.rate.date = $rateDate.ToString('dd.MM.yyyy') }
            else { $script:Usage.rate.date = (Get-Date ([string]$rateDate)).ToString('dd.MM.yyyy') }
          } catch { $script:Usage.rate.date = [string]$parsed.Date }
          $script:Usage.rate.isoDate = Get-Date -Format 'yyyy-MM-dd'
          Save-Usage
          Update-CostLine
        } else {
          Write-Log 'rate: в ответе ЦБ нет USD'
        }
      }
    } catch { Write-Log "rate: ошибка $($_.Exception.Message)" }
  }

  if (-not $script:NextBalanceAt -or (Get-Date) -gt $script:NextBalanceAt) {
    $script:NextBalanceAt = (Get-Date).AddMinutes(10)
    Refresh-Balance
    if ($script:Usage.rate.isoDate -ne (Get-Date -Format 'yyyy-MM-dd')) { Refresh-Rate }
  }

  # подчищаем осиротевшие временные файлы синтеза
  if (-not $script:NextSweepAt -or (Get-Date) -gt $script:NextSweepAt) {
    $script:NextSweepAt = (Get-Date).AddMinutes(5)
    try {
      Get-ChildItem $CacheDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(edge|silero|sapi|voice)-' -and $_.LastWriteTime -lt (Get-Date).AddMinutes(-3) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
  }

  if ($script:ModelTask -and $script:ModelTask.IsCompleted) {
    $task = $script:ModelTask
    $script:ModelTask = $null
    try {
      $response = $task.Result
      if ($response.IsSuccessStatusCode) {
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = $json | ConvertFrom-Json
        $script:Models = @($parsed.data | Sort-Object { if ($_.pricing -and [double]$_.pricing.prompt -eq 0) { 0 } else { 1 } }, name)
        Apply-Models
        Set-Status 'Список моделей обновлён'
      } else {
        Set-Status "Список не загрузился: HTTP $([int]$response.StatusCode)"
      }
    } catch {
      Set-Status "Список не загрузился: $($_.Exception.Message)"
    }
  }

  if ($script:Pending.Count) {
    foreach ($item in @($script:Pending)) {
      if ($item.Kind -eq 'file') {
        $outFile = $item.Req.OutFile
        # если синтез идёт в отдельном процессе — дожидаемся его выхода,
        # иначе файл ещё не дописан
        $hasProc = $false
        if ($item.Req -is [System.Collections.IDictionary]) { $hasProc = $item.Req.Contains('Proc') }
        else { $hasProc = ($item.Req.PSObject.Properties.Name -contains 'Proc') }
        if ($hasProc -and -not $item.Req.Proc.HasExited) { continue }
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
            if ($Cfg.yandexKey -and $script:ActiveProvider -ne 'yandex' -and $item.Req.Text) {
              Set-Status 'Движок не ответил — озвучиваю через Яндекс'
              Write-Log 'fallback: воркер вернул ошибку, переключаюсь на Яндекс'
              Start-Speaking $item.Req.Text 'запасной (Яндекс)' 'yandex'
            } else {
              Set-Status "Движок не ответил: $why"
              $script:Session = $null
            }
            continue
          }
          # ждём файл, но не бесконечно
          if (((Get-Date) - $item.Requested).TotalSeconds -gt 40) {
            $script:Pending.Remove($item)
            Remove-Item $outFile, $item.Req.RequestFile -Force -ErrorAction SilentlyContinue
            Write-Log 'file: синтез не ответил'
            if ($Cfg.yandexKey -and $script:ActiveProvider -ne 'yandex' -and $item.Req.Text) {
              Set-Status 'Движок не ответил — озвучиваю через Яндекс'
              Write-Log 'fallback: синтез не уложился в 40 секунд, переключаюсь на Яндекс'
              Start-Speaking $item.Req.Text 'запасной (Яндекс)' 'yandex'
            } else {
              Set-Status 'Синтез не ответил за 40 секунд'
              $script:Session = $null
            }
          }
          continue
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
          if ($Cfg.yandexKey -and $script:ActiveProvider -ne 'yandex' -and $item.Req.Text) {
            Set-Status 'Движок не ответил — озвучиваю через Яндекс'
            Write-Log 'fallback: синтез не удался, переключаюсь на Яндекс'
            Start-Speaking $item.Req.Text 'запасной (Яндекс)' 'yandex'
          } else {
            Set-Status "Ошибка разбора звука: $($_.Exception.Message)"
            $script:Session = $null
          }
        }
        continue
      }
      if ($item.Kind -eq 'silero') {
        if (-not (Test-Path $item.Req.PcmFile)) { continue }
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
          if ($Cfg.yandexKey -and $script:ActiveProvider -ne 'yandex' -and $item.Req.Text) {
            Set-Status 'Движок не ответил — озвучиваю через Яндекс'
            Write-Log 'fallback: синтез не удался, переключаюсь на Яндекс'
            Start-Speaking $item.Req.Text 'запасной (Яндекс)' 'yandex'
          } else {
            Set-Status "Ошибка Silero: $($_.Exception.Message)"
            $script:Session = $null
          }
        }
        continue
      }
      if (-not $item.Task.IsCompleted) { continue }
      $script:Pending.Remove($item)
      try {
        if ($item.Kind -eq 'pipe') {
          $bytes = $item.Pipe.Stream.ToArray()
          try { [void]$item.Pipe.Process.WaitForExit(5000) } catch { }
          ConvertTo-WavFile -Pcm $bytes -Path $item.Path -SampleRate $item.SampleRate
          if ($script:Session) { $script:Session.Files[$item.Index] = $item.Path }
          Write-Log "chunk $($item.Index): $($bytes.Length) байт (piper, $($Cfg.piperVoice))"
          Try-Play-Next
          continue
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
              continue
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
  }

  try {
    $spooled = Get-ChildItem $SpoolDir -Filter '*.txt' -File | Sort-Object Name | Select-Object -First 1
    if ($spooled) {
      $content = [System.IO.File]::ReadAllText($spooled.FullName)
      Remove-Item $spooled.FullName -Force -ErrorAction SilentlyContinue
      if ($spooled.Name -match '-stop-') { Stop-Speaking }
      elseif ($content.Trim()) { Start-Speaking $content 'spool' }
    }
  } catch { }
})

# ---------------------------------------------------------------- окно, хоткеи, трей

$speedChoices = @(0.75, 1.0, 1.25, 1.5, 2.0)
foreach ($speed in $speedChoices) {
  $label = if ($speed -eq 1) { '1×' } else { ('{0}×' -f $speed) }
  [void]$uiSpeedCombo.Items.Add($label)
}
$speedIndex = 0
for ($i = 0; $i -lt $speedChoices.Count; $i++) {
  if ([Math]::Abs([double]$speedChoices[$i] - [double]$Cfg.speed) -lt 0.01) { $speedIndex = $i; break }
}
$uiSpeedCombo.SelectedIndex = $speedIndex

$uiHotkeyHint.Text = '{0} — выделенное · {1} — голос' -f $Cfg.speakSelectionHotkey, $Cfg.sttHotkey

# движок распознавания речи
$script:SttProviders = @('openrouter', 'whisper')
$sttProviderLabels = @('OpenRouter (облако)', 'faster-whisper (локально, офлайн)')
foreach ($label in $sttProviderLabels) { [void]$uiSttProviderCombo.Items.Add($label) }
$sttProviderIndex = [Array]::IndexOf($script:SttProviders, [string]$Cfg.sttProvider)
if ($sttProviderIndex -lt 0) { $sttProviderIndex = 0; $Cfg.sttProvider = 'openrouter' }
$uiSttProviderCombo.SelectedIndex = $sttProviderIndex
$uiSttModelBox.Text = Get-SttCurrentModel

# источник озвучки: облачные, локальные (Silero/Piper/Edge/SAPI) и модели OpenRouter
foreach ($id in $script:Providers.Keys) { [void]$uiProviderCombo.Items.Add($script:Providers[$id].Title) }
$providerIndex = [Array]::IndexOf(@($script:Providers.Keys), [string]$Cfg.provider)
if ($providerIndex -lt 0) { $providerIndex = 0; $Cfg.provider = 'yandex' }
$uiProviderCombo.SelectedIndex = $providerIndex
$uiChkNumbers.IsChecked = [bool]$Cfg.readNumbers
$uiChkEnglish.IsChecked = [bool]$Cfg.englishAsEnglish
Apply-Provider

$scale = 1.0
try {
  $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($win)
  if ($dpi.DpiScaleX -gt 0) { $scale = $dpi.DpiScaleX }
} catch { }
$work = [System.Windows.SystemParameters]::WorkArea
if ($Cfg.window.left -ne $null -and $Cfg.window.top -ne $null) {
  $win.Left = [double]$Cfg.window.left
  $win.Top  = [double]$Cfg.window.top
} else {
  $win.Left = $work.Right / $scale - 410
  $win.Top  = $work.Bottom / $scale - 170
}
# окно не должно уезжать за экран (например, если сменилось разрешение)
$winWidth = 400; $winHeight = 170
$maxLeft = $work.Right - $winWidth
$maxTop = $work.Bottom - $winHeight
if ($win.Left -gt $maxLeft) { $win.Left = $maxLeft }
if ($win.Top -gt $maxTop) { $win.Top = $maxTop }
if ($win.Left -lt $work.Left) { $win.Left = $work.Left }
if ($win.Top -lt $work.Top) { $win.Top = $work.Top }

$win.Add_Closed({
  try {
    $Cfg.window.left = [int]$win.Left
    $Cfg.window.top  = [int]$win.Top
  } catch { }
  Save-Config
})

$win.Show()
$script:Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
Set-Content -Path (Join-Path $Root 'tts-overlay.pid') -Value $PID -Encoding ascii
$registered = Register-Hotkeys

# счётчик затрат: остаток OpenRouter, курс доллара, список моделей для цен
Update-CostLine
Refresh-Balance
Refresh-Rate
# список моделей OpenRouter и локальные воркеры грузим заранее, чтобы первая фраза не ждала
$warmup = (Get-ConfiguredProvider).Warmup
if ($warmup) { & $warmup }
# воркер распознавания тоже поднимаем сразу: он грузит модель в фоне
Start-SttWorker $true

$source = [System.Windows.Interop.HwndSource]::FromHwnd($script:Hwnd)
$hook = [System.Windows.Interop.HwndSourceHook]{
  param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
  if ($msg -eq 0x0312) {
    $hotkeyId = $wParam.ToInt32()
    $now = [DateTime]::UtcNow
    $last = if ($script:HotkeySeen.ContainsKey($hotkeyId)) { $script:HotkeySeen[$hotkeyId] } else { [DateTime]::MinValue }
    if (($now - $last).TotalMilliseconds -ge 400) {
      $script:HotkeySeen[$hotkeyId] = $now
      Write-Log "hotkey id=$hotkeyId"
      switch ($hotkeyId) {
        1 { $script:QueueSelection = [DateTime]::UtcNow.AddMilliseconds(250) }
        2 { $script:QueueClipboard = [DateTime]::UtcNow.AddMilliseconds(120) }
        3 { Stop-Speaking }
        4 { Start-VoiceRecording }
      }
    }
  }
  return [IntPtr]::Zero
}
[void]$source.AddHook($hook)

$tray = [System.Windows.Forms.NotifyIcon]::new()
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = 'Озвучка выделенного (OpenRouter TTS)'
$tray.Visible = $true
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$itemShow = $menu.Items.Add('Показать / скрыть оверлей')
$itemSpeak = $menu.Items.Add('Озвучить буфер обмена')
$itemStop = $menu.Items.Add('Стоп')
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$itemExit = $menu.Items.Add('Выход')
$tray.ContextMenuStrip = $menu
$itemShow.Add_Click({ if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() } })
$itemSpeak.Add_Click({ Speak-Clipboard })
$itemStop.Add_Click({ Stop-Speaking })
$itemExit.Add_Click({ $win.Close(); $tray.Visible = $false; $script:Timer.Stop(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$tray.Add_MouseDoubleClick({ if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() } })

$script:Timer.Start()

if ($registered.Count) {
  Set-Status ('Готово. {0} — озвучить выделенное, {1} — буфер, {2} — голос' -f $Cfg.speakSelectionHotkey, $Cfg.speakClipboardHotkey, $Cfg.sttHotkey)
} else {
  Set-Status 'Горячие клавиши заняты — работаю через кнопки и трей'
}

$sourceLabel = & (Get-ConfiguredProvider).Source
Write-Log "start: окно $([int]$win.Left),$([int]$win.Top) источник $sourceLabel"

if ($Start) { Write-Log 'start flag: оверлей запущен' }

[System.Windows.Threading.Dispatcher]::Run()
Stop-Speaking $false
if ($script:SileroWorker) { try { $script:SileroWorker.Kill() } catch { } }
if ($script:SttWorker) { try { $script:SttWorker.Kill() } catch { } }
Remove-Item (Join-Path $Root 'tts-overlay.pid') -Force -ErrorAction SilentlyContinue
$tray.Visible = $false
$tray.Dispose()
Write-Log 'exit'

