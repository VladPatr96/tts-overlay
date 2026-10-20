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
. (Join-Path $Root 'lib-text.ps1')
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

function Write-Log([string]$Message) {
  try {
    Add-Content -Path $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8
  } catch { }
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

function Save-Config {
  try {
    ($Cfg | ConvertTo-Json -Depth 5) | Set-Content -Path $ConfigPath -Encoding utf8
  } catch { Write-Log "config: не сохранён ($($_.Exception.Message))" }
}

if (-not (Test-Path $ConfigPath)) { Save-Config }

# словарь произношения: создаём с базовыми записями, если его ещё нет
Save-DefaultPronounce
$script:Pronounce = Get-PronounceMap
Write-Log "словарь произношения: $($script:Pronounce.Count) записей"

# ---------------------------------------------------------------- ключ OpenRouter

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
$script:ActiveProvider = [string]$Cfg.provider
# ---------------------------------------------------------------- учёт затрат

$UsagePath = Join-Path $Root 'usage.json'

$script:Usage = @{
  keys    = @{}
  rate    = @{ usdRub = 0.0; date = ''; isoDate = '' }
  balance = @{ openrouter = @{ left = 0.0; total = 0.0; used = 0.0; at = '' } }
  stt     = @{ days = @{} }
}
if (Test-Path $UsagePath) {
  try {
    $loaded = Get-Content $UsagePath -Raw | ConvertFrom-Json -AsHashtable
    if ($loaded.keys)    { $script:Usage.keys = $loaded.keys }
    if ($loaded.rate)    { $script:Usage.rate = $loaded.rate }
    if ($loaded.balance) { $script:Usage.balance = $loaded.balance }
    if ($loaded.stt)     { $script:Usage.stt = $loaded.stt }
  } catch { Write-Log "usage: не прочитан ($($_.Exception.Message))" }
}
if (-not $script:Usage.stt) { $script:Usage.stt = @{ days = @{} } }
if (-not $script:Usage.stt.days) { $script:Usage.stt.days = @{} }

function Save-Usage {
  try { ($script:Usage | ConvertTo-Json -Depth 6) | Set-Content -Path $UsagePath -Encoding utf8 } catch { }
}

function Format-Rub([double]$Value) { '{0:N2} ₽' -f $Value }
function Format-Usd([double]$Value) {
  if ([Math]::Abs($Value) -lt 0.01) { return ('${0:N4}' -f $Value) }
  return ('${0:N2}' -f $Value)
}
function Format-UsdWhole([double]$Value) { '${0:N2}' -f $Value }

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

function Get-UsageEntry([string]$Key) {
  if (-not $script:Usage.keys.ContainsKey($Key)) {
    $script:Usage.keys[$Key] = @{ chars = 0; requests = 0; rub = 0.0; usd = 0.0; days = @{} }
  }
  $entry = $script:Usage.keys[$Key]
  if (-not $entry.ContainsKey('days')) { $entry.days = @{} }
  return $entry
}

function Get-ModelPricePerChar {
  foreach ($model in $script:Models) {
    if ($model.id -eq $Cfg.model -and $model.pricing) { return [double]$model.pricing.prompt }
  }
  return 0.0
}

function Get-CostEstimate([int]$Chars) {
  $rub = 0.0
  $usd = 0.0
  if ($script:ActiveProvider -eq 'yandex') {
    $rub = ($Chars / 1000.0) * [double]$Cfg.yandexRubPer1kChars
  } elseif ($script:ActiveProvider -eq 'openrouter') {
    $usd = $Chars * (Get-ModelPricePerChar)
  }
  # piper — локально и бесплатно
  return @{ rub = $rub; usd = $usd }
}

function Add-Usage([string]$Text) {
  $day = Get-Date -Format 'yyyy-MM-dd'
  $key = Get-ProviderKey
  $entry = Get-UsageEntry $key
  if (-not $entry.days.ContainsKey($day)) {
    $entry.days[$day] = @{ chars = 0; requests = 0; rub = 0.0; usd = 0.0 }
  }
  $dayEntry = $entry.days[$day]
  $chars = $Text.Length
  $cost = Get-CostEstimate $chars
  $dayEntry.chars += $chars
  $dayEntry.requests += 1
  $dayEntry.rub += $cost.rub
  $dayEntry.usd += $cost.usd
  $entry.chars += $chars
  $entry.requests += 1
  $entry.rub += $cost.rub
  $entry.usd += $cost.usd
  Save-Usage
  Update-CostLine
}

function Add-SttUsage([double]$Seconds, [double]$Usd = 0.0) {
  # распознавание тарифицируется по секундам звука, поэтому счётчик свой
  $day = Get-Date -Format 'yyyy-MM-dd'
  if (-not $script:Usage.stt.days.ContainsKey($day)) {
    $script:Usage.stt.days[$day] = @{ seconds = 0.0; requests = 0; usd = 0.0 }
  }
  $dayEntry = $script:Usage.stt.days[$day]
  $dayEntry.seconds += $Seconds
  $dayEntry.requests += 1
  $dayEntry.usd += $Usd
  Save-Usage
  Update-CostLine
}

function Get-SttTotals {
  $seconds = 0.0
  $requests = 0
  $usd = 0.0
  foreach ($dayEntry in $script:Usage.stt.days.Values) {
    $seconds += [double]$dayEntry.seconds
    $requests += [int]$dayEntry.requests
    $usd += [double]$dayEntry.usd
  }
  return @{ seconds = $seconds; requests = $requests; usd = $usd }
}

function Update-SelInfo {
  $sel = $script:Selection
  if (-not $sel) { return }
  $cost = Get-CostEstimate $sel.chars
  $money = if ($Cfg.provider -eq 'piper') { 'бесплатно (локально)' }
           elseif ($Cfg.provider -eq 'yandex') { Format-Rub $cost.rub }
           else { Format-Usd $cost.usd }
  $rub = if ($Cfg.provider -eq 'openrouter' -and $cost.usd -gt 0) { ' (≈ ' + (Format-Rub ($cost.usd * [double]$script:Usage.rate.usdRub)) + ')' } else { '' }
  try { $uiSelInfo.Text = "Выделено: {0:N0} симв. ≈ {1}{2} · {3}" -f $sel.chars, $money, $rub, (Get-ProviderLabel) } catch { }
}

function Update-CostLine {
  $day = Get-Date -Format 'yyyy-MM-dd'
  $key = Get-ProviderKey
  $entry = Get-UsageEntry $key
  $dayEntry = if ($entry.days.ContainsKey($day)) { $entry.days[$day] } else { @{ chars = 0; requests = 0; rub = 0.0; usd = 0.0 } }
  $rate = [double]$script:Usage.rate.usdRub
  $todayRub = [double]$dayEntry.rub + [double]$dayEntry.usd * $rate
  $totalRub = [double]$entry.rub + [double]$entry.usd * $rate
  $balance = $script:Usage.balance.openrouter

  $line = if ($Cfg.provider -in @('piper', 'silero')) {
    "Сегодня: {0:N0} симв. · бесплатно (локально) · {1}" -f $dayEntry.chars, (Get-ProviderLabel)
  } else {
    "Сегодня: {0:N0} симв. · {1} · {2}   ·   {3}" -f $dayEntry.chars, (Format-Rub $todayRub), (Format-Usd ([double]$dayEntry.usd)), (Get-ProviderLabel)
  }
  if ($Cfg.provider -eq 'openrouter' -and $balance.at) {
    $line += ("   ·   остаток {0} (≈ {1})" -f (Format-UsdWhole ([double]$balance.left)), (Format-Rub ([double]$balance.left * $rate)))
  }
  try { $uiCostLine.Text = $line } catch { }

  $details = @()
  $details += "Источник: {0}" -f (Get-ProviderLabel)
  if ($Cfg.provider -in @('piper', 'silero')) {
    $details += "Сегодня: {0:N0} симв., {1} запрос(ов) — бесплатно (локально)" -f $dayEntry.chars, $dayEntry.requests
    $details += "Всего по этому источнику: {0:N0} симв., {1} запрос(ов) — бесплатно" -f $entry.chars, $entry.requests
  } else {
    $details += "Сегодня: {0:N0} симв., {1} запрос(ов) — {2} ({3})" -f $dayEntry.chars, $dayEntry.requests, (Format-Rub $todayRub), (Format-Usd ([double]$dayEntry.usd))
    $details += "Всего по этому источнику: {0:N0} симв., {1} запрос(ов) — {2} ({3})" -f $entry.chars, $entry.requests, (Format-Rub $totalRub), (Format-Usd ([double]$entry.usd))
  }
  if ($rate -gt 0) { $details += "Курс ЦБ: {0:N2} ₽/$ ({1})" -f $rate, $script:Usage.rate.date }
  $sttDay = if ($script:Usage.stt.days.ContainsKey($day)) { $script:Usage.stt.days[$day] } else { @{ seconds = 0.0; requests = 0; usd = 0.0 } }
  $sttTotals = Get-SttTotals
  $sttRub = [double]$sttDay.usd * $rate
  $details += "Распознавание: сегодня {0:N1} с, {1} запрос(ов) — {2} ({3})" -f [double]$sttDay.seconds, [int]$sttDay.requests, (Format-Rub $sttRub), (Format-Usd ([double]$sttDay.usd))
  $details += "Распознавание всего: {0:N1} с, {1} запрос(ов) — {2}" -f $sttTotals.seconds, $sttTotals.requests, (Format-Usd $sttTotals.usd)
  if ($Cfg.provider -eq 'openrouter' -and $balance.at) {
    $details += "OpenRouter: осталось {0} из {1}, израсходовано {2} (обновлено {3})" -f (Format-UsdWhole ([double]$balance.left)), (Format-UsdWhole ([double]$balance.total)), (Format-UsdWhole ([double]$balance.used)), $balance.at
  }
  if ($Cfg.provider -eq 'yandex' -and [double]$Cfg.yandexBalanceStart -gt 0) {
    $left = [double]$Cfg.yandexBalanceStart - ([double]$entry.rub - [double]$Cfg.yandexSpentAtStart)
    $details += "Яндекс: осталось ≈ {0} (введено вручную {1})" -f (Format-Rub $left), (Format-Rub ([double]$Cfg.yandexBalanceStart))
  }
  if ($Cfg.provider -eq 'piper') {
    $details += "Piper: локальный синтез, интернет и оплата не нужны"
  }
  if ($Cfg.provider -eq 'silero') {
    $details += "Silero: локальный синтез, интернет и оплата не нужны"
  }
  try { $uiCostDetails.Text = ($details -join "`n") } catch { }
}

function Refresh-Balance {
  if (-not $script:OpenRouterKey) { return }
  try {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'https://openrouter.ai/api/v1/credits')
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:OpenRouterKey)
    $script:BalanceTask = $script:Http.SendAsync($request)
  } catch { Write-Log "balance: $($_.Exception.Message)" }
}

function Refresh-Rate {
  try {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'https://www.cbr-xml-daily.ru/daily_json.js')
    $script:RateTask = $script:Http.SendAsync($request)
  } catch { Write-Log "rate: $($_.Exception.Message)" }
}

$script:HotkeySeen = @{}
$script:QueueSelection = $null
$script:QueueClipboard = $null

function Set-Status([string]$Text) {
  try { $uiStatus.Text = $Text } catch { }
}

# ---------------------------------------------------------------- текст и кэш

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

# --- Silero: постоянный воркер, модель грузится один раз ---

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

# ---------------------------------------------------------------- запрос к TTS

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

# ---------------------------------------------------------------- выделенное и буфер

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

# ---------------------------------------------------------------- список моделей и голосов

function Load-Models {
  try {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $ModelsUrl)
    $script:ModelTask = $script:Http.SendAsync($request)
    Set-Status 'Загружаю список TTS-моделей…'
  } catch {
    Set-Status "Не загрузил список: $($_.Exception.Message)"
  }
}

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

function Get-VoiceFallback([string]$ModelId) {
  # в карточке бесплатной Fish Audio голосов нет, но параметр voice она понимает:
  # единственное рабочее имя — alloy (остальные дают 400)
  if ($ModelId -like 'fish-audio/*') { return @('alloy') }
  return @()
}

function Apply-Voices {
  $uiVoiceCombo.Items.Clear()
  if ($Cfg.provider -in @('piper', 'silero', 'edge', 'sapi')) {
    $uiVoiceCombo.ToolTip = 'Локальный голос (работает без интернета).'
    $script:Voices = @(Get-LocalVoices)
    foreach ($name in $script:Voices) { [void]$uiVoiceCombo.Items.Add($name) }
    $current = switch ($Cfg.provider) {
      'silero' { [string]$Cfg.sileroSpeaker }
      'edge'   { [string]$Cfg.edgeVoice }
      'sapi'   { [string]$Cfg.sapiVoice }
      default  { [string]$Cfg.piperVoice }
    }
    $index = [Array]::IndexOf($script:Voices, $current)
    if ($index -lt 0) {
      $index = 0
      $current = [string]$script:Voices[0]
      switch ($Cfg.provider) {
        'silero' { $Cfg.sileroSpeaker = $current }
        'edge'   { $Cfg.edgeVoice = $current }
        'sapi'   { $Cfg.sapiVoice = $current }
        default  { $Cfg.piperVoice = $current }
      }
      Save-Config
    }
    $uiVoiceCombo.SelectedIndex = $index
    $uiModelInfo.Text = "$(Get-ProviderLabel) · бесплатно"
    return
  }
  if ($Cfg.provider -eq 'yandex') {
    $uiVoiceCombo.ToolTip = 'Голос Яндекс SpeechKit.'
    $script:Voices = @($script:YandexVoices.Keys)
    foreach ($name in $script:YandexVoices.Keys) {
      [void]$uiVoiceCombo.Items.Add(('{0} — {1}' -f $name, $script:YandexVoices[$name]))
    }
    $index = [Array]::IndexOf($script:Voices, [string]$Cfg.yandexVoice)
    if ($index -lt 0) {
      $index = 0
      $Cfg.yandexVoice = [string]$script:Voices[0]
      Save-Config
    }
    $uiVoiceCombo.SelectedIndex = $index
    $uiModelInfo.Text = "Яндекс SpeechKit · $($Cfg.yandexLang) · голос $($Cfg.yandexVoice)"
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
  $uiModelBlock.Visibility = if ($Cfg.provider -eq 'openrouter') { 'Visible' } else { 'Collapsed' }
  $uiBtnReload.IsEnabled = ($Cfg.provider -eq 'openrouter')
  Apply-Voices
  if ($Cfg.provider -eq 'openrouter' -and -not $script:Models.Count) { Load-Models }
  Update-CostLine
  Update-SelInfo
}

# ---------------------------------------------------------------- горячие клавиши

$script:HotkeyMods = @{ ctrl = 2; alt = 1; shift = 4; win = 8 }

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

# ---------------------------------------------------------------- распознавание речи

$script:SttWorker = $null
$script:Voice = $null
$script:SttTask = $null
$script:VoiceKeyVk = 0x56

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

function Set-ClipboardText([string]$Text) {
  if (-not $Text) { return $false }
  for ($i = 0; $i -lt 5; $i++) {
    try { [System.Windows.Forms.Clipboard]::SetText($Text); return $true }
    catch { Start-Sleep -Milliseconds 120 }
  }
  return $false
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
  if ($uiSettings.Visibility -eq 'Visible' -and $Cfg.provider -eq 'openrouter' -and -not $uiModelCombo.Items.Count) { Load-Models }
})

$uiTitleBar.Add_MouseLeftButtonDown({
  try { $win.DragMove() } catch { }
})

$uiModelCombo.Add_SelectionChanged({
  if ($uiModelCombo.SelectedIndex -lt 0 -or $uiModelCombo.SelectedIndex -ge $script:Models.Count) { return }
  if ($Cfg.provider -ne 'openrouter') { return }
  $model = $script:Models[$uiModelCombo.SelectedIndex]
  $Cfg.model = $model.id
  $script:Voices = @($model.supported_voices)
  Apply-Voices
  $uiModelInfo.Text = "Модель: $($model.id)"
  Save-Config
})

$uiProviderCombo.Add_SelectionChanged({
  if ($uiProviderCombo.SelectedIndex -lt 0) { return }
  $Cfg.provider = [string]$script:Providers[$uiProviderCombo.SelectedIndex]
  Save-Config
  Apply-Provider
})

$uiVoiceCombo.Add_SelectionChanged({
  if ($uiVoiceCombo.SelectedIndex -lt 0 -or $uiVoiceCombo.SelectedIndex -ge $script:Voices.Count) { return }
  if ($Cfg.provider -eq 'yandex') {
    $Cfg.yandexVoice = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
    $uiModelInfo.Text = "Яндекс SpeechKit · $($Cfg.yandexLang) · голос $($Cfg.yandexVoice)"
  } elseif ($Cfg.provider -eq 'piper') {
    $Cfg.piperVoice = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
    $uiModelInfo.Text = "Piper · локально · $($Cfg.piperVoice)"
  } elseif ($Cfg.provider -eq 'silero') {
    $Cfg.sileroSpeaker = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
    $uiModelInfo.Text = "Silero · локально · $($Cfg.sileroSpeaker)"
  } elseif ($Cfg.provider -eq 'edge') {
    $Cfg.edgeVoice = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
    $uiModelInfo.Text = "Edge TTS · бесплатно · $($Cfg.edgeVoice)"
  } elseif ($Cfg.provider -eq 'sapi') {
    $Cfg.sapiVoice = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
    $uiModelInfo.Text = "SAPI 5 · встроенный голос · $($Cfg.sapiVoice)"
  } else {
    $Cfg.voice = [string]$script:Voices[$uiVoiceCombo.SelectedIndex]
  }
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
          } elseif ($script:ActiveProvider -eq 'yandex') {
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
$script:Providers = @('yandex', 'edge', 'silero', 'sapi', 'piper', 'openrouter')
$providerLabels = @('Яндекс SpeechKit', 'Edge TTS (бесплатно)', 'Silero (локально, бесплатно)', 'SAPI 5 (встроенный в Windows)', 'Piper (локально, бесплатно)', 'OpenRouter (модели)')
foreach ($label in $providerLabels) { [void]$uiProviderCombo.Items.Add($label) }
$providerIndex = [Array]::IndexOf($script:Providers, [string]$Cfg.provider)
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
if ($Cfg.provider -eq 'openrouter') { Load-Models }
# локальную модель грузим заранее, чтобы первая фраза не ждала
if ($Cfg.provider -eq 'silero') { Start-SileroWorker $true }
if ($Cfg.provider -eq 'edge') { Start-EdgeWorker $true }
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

$sourceLabel = switch ($Cfg.provider) {
  'yandex' { "яндекс/$($Cfg.yandexVoice)" }
  'edge'   { "edge/$($Cfg.edgeVoice)" }
  'silero' { "silero/$($Cfg.sileroSpeaker)" }
  'sapi'   { "sapi/$($Cfg.sapiVoice)" }
  'piper'  { "piper/$($Cfg.piperVoice)" }
  default  { "$($Cfg.model)/$($Cfg.voice)" }
}
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

