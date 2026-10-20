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
  return (& (Get-ActiveProvider).Cost $Chars)
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
  $provider = Get-ConfiguredProvider
  $money = switch ($provider.Currency) {
    'rub'   { Format-Rub $cost.rub }
    'usd'   { Format-Usd $cost.usd }
    default { if ($provider.Local) { 'бесплатно (локально)' } else { 'бесплатно' } }
  }
  $rub = if ($provider.Currency -eq 'usd' -and $cost.usd -gt 0) { ' (≈ ' + (Format-Rub ($cost.usd * [double]$script:Usage.rate.usdRub)) + ')' } else { '' }
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
  $provider = Get-ConfiguredProvider

  $line = if ($provider.Local) {
    "Сегодня: {0:N0} симв. · бесплатно (локально) · {1}" -f $dayEntry.chars, (Get-ProviderLabel)
  } else {
    "Сегодня: {0:N0} симв. · {1} · {2}   ·   {3}" -f $dayEntry.chars, (Format-Rub $todayRub), (Format-Usd ([double]$dayEntry.usd)), (Get-ProviderLabel)
  }
  if ($provider.LineExtra) { $line += (& $provider.LineExtra $balance $rate) }
  try { $uiCostLine.Text = $line } catch { }

  $details = @()
  $details += "Источник: {0}" -f (Get-ProviderLabel)
  if ($provider.Local) {
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
  if ($provider.DetailsExtra) {
    $extra = & $provider.DetailsExtra $entry $balance $rate
    if ($extra) { $details += $extra }
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
