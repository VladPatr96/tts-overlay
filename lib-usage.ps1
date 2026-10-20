# lib-usage.ps1 — учёт затрат, баланс OpenRouter, курс ЦБ. Подключается из tts-overlay.ps1 (dot-sourcing).
# Использует общее состояние главного скрипта: $Cfg, $UsagePath, $script:Usage, $script:Models, $script:Http, $script:Selection, элементы окна ($uiCostLine и др.).

function Import-Usage {
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
}

function Save-Usage {
  try { ($script:Usage | ConvertTo-Json -Depth 6) | Set-Content -Path $UsagePath -Encoding utf8 } catch { }
}

function Format-Rub([double]$Value) { '{0:N2} ₽' -f $Value }

function Format-Usd([double]$Value) {
  if ([Math]::Abs($Value) -lt 0.01) { return ('${0:N4}' -f $Value) }
  return ('${0:N2}' -f $Value)
}

function Format-UsdWhole([double]$Value) { '${0:N2}' -f $Value }

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
