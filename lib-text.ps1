# ---------------------------------------------------------------- разбор текста перед синтезом
# Стандарты: SSML 1.1 (W3C) — <sub alias> (произношение), <phoneme alphabet="ipa"> (фонетика),
# <say-as> (числа/буквы), <break>/<prosody>/<emphasis> (интонация), <lang> (смена языка).
# Словарь хранится в стандартном формате лексикона: "слово<TAB>произношение" (CMUdict/LEXICON).

function Get-WordForm([int]$n, [string]$one, [string]$few, [string]$many) {
  $mod100 = $n % 100
  $mod10 = $n % 10
  if ($mod100 -ge 11 -and $mod100 -le 14) { return $many }
  if ($mod10 -eq 1) { return $one }
  if ($mod10 -ge 2 -and $mod10 -le 4) { return $few }
  return $many
}

# слова для чисел: одни таблицы на все функции ниже
$script:Ones = @('ноль','один','два','три','четыре','пять','шесть','семь','восемь','девять',
                 'десять','одиннадцать','двенадцать','тринадцать','четырнадцать','пятнадцать',
                 'шестнадцать','семнадцать','восемнадцать','девятнадцать')
$script:Tens = @{ 20='двадцать';30='тридцать';40='сорок';50='пятьдесят';60='шестьдесят';70='семьдесят';80='восемьдесят';90='девяносто' }
$script:Hundreds = @('сто','двести','триста','четыреста','пятьсот','шестьсот','семьсот','восемьсот','девятьсот')
$script:OnesFeminine = @('','одна','две','три','четыре','пять','шесть','семь','восемь','девять')
# родительный падеж (даты, годы)
$script:OnesGenitive = @('нулевого','первого','второго','третьего','четвёртого','пятого','шестого','седьмого','восьмого','девятого',
                         'десятого','одиннадцатого','двенадцатого','тринадцатого','четырнадцатого','пятнадцатого',
                         'шестнадцатого','семнадцатого','восемнадцатого','девятнадцатого')
$script:HundredsGenitive = @('ста','двухсот','трёхсот','четырёхсот','пятисот','шестисот','семисот','восьмисот','девятисот')

function Convert-ScaleToWords([int]$Count, [string]$One, [string]$Few, [string]$Many, [scriptblock]$Words = $null) {
  # «два миллиона», «пять тысяч»; единица — просто «миллион»/«тысяча»
  if ($Count -eq 1) { return $One }
  $text = if ($Words) { & $Words $Count } else { Convert-NumberToWords $Count }
  return $text + ' ' + (Get-WordForm $Count $One $Few $Many)
}

function Get-ScaleParts([int]$Millions, [int]$Thousands, [scriptblock]$ThousandsWords = $null) {
  # слова для миллионов и тысяч числа (пустой массив, если их нет)
  $parts = @()
  if ($Millions -gt 0) { $parts += Convert-ScaleToWords $Millions 'миллион' 'миллиона' 'миллионов' }
  if ($Thousands -gt 0) { $parts += Convert-ScaleToWords $Thousands 'тысяча' 'тысячи' 'тысяч' $ThousandsWords }
  return $parts
}

function Convert-NumberToWords([int]$n) {
  if ($n -eq 0) { return 'ноль' }
  $millions = [Math]::Floor($n / 1000000)
  $n = $n % 1000000
  $thousands = [Math]::Floor($n / 1000)
  $rest = $n % 1000
  $parts = @(Get-ScaleParts $millions $thousands)
  if ($rest -gt 0 -or -not $parts.Count) {
    if ($rest -ge 100) {
      $h = [Math]::Floor($rest / 100)
      $parts += $script:Hundreds[$h - 1]
      $r = $rest % 100
      if ($r -gt 0) { $parts += (Convert-NumberToWords $r) }
    } elseif ($rest -ge 20) {
      $t = [int](([Math]::Floor($rest / 10) % 10) * 10)
      $parts += $script:Tens[$t]
      $u = $rest % 10
      if ($u -gt 0) { $parts += $script:Ones[$u] }
    } else {
      $parts += $script:Ones[$rest]
    }
  }
  return ($parts -join ' ')
}

function Convert-YearToWords([int]$year) {
  # 2026 -> "две тысячи девятьсот девяносто шестого года"
  $millions = [Math]::Floor($year / 1000000)
  $year = $year % 1000000
  $thousands = [Math]::Floor($year / 1000)
  $rest = $year % 1000
  $parts = @(Get-ScaleParts $millions $thousands { param($n) $script:OnesFeminine[$n] })
  if ($rest -gt 0) {
    if ($rest -ge 100) {
      $h = [Math]::Floor($rest / 100)
      $parts += $script:HundredsGenitive[$h - 1]
      $r = $rest % 100
      if ($r -gt 0) { $parts += (Convert-RemainderGenitive $r) }
    } else {
      $parts += (Convert-RemainderGenitive $rest)
    }
  }
  return (($parts -join ' ') + ' года')
}

function Convert-RemainderGenitive([int]$n) {
  if ($n -ge 20) {
    $t = [int](([Math]::Floor($n / 10) % 10) * 10)
    $u = $n % 10
    if ($u -eq 0) { return $script:Tens[$t] }
    return $script:Tens[$t] + ' ' + $script:OnesGenitive[$u]
  }
  return $script:OnesGenitive[$n]
}

function Convert-DayToGenitive([int]$day) {
  # 12 -> "двенадцатого" (родительный падеж, как в датах)
  if ($day -le 19) { return $script:OnesGenitive[$day] }
  if ($day -eq 20) { return 'двадцатого' }
  if ($day -le 31) { return 'тридцать ' + $script:OnesGenitive[(($day - 21) % 10) + 1] }
  return (Convert-NumberToWords $day)
}

function Convert-FractionToWords([string]$digits) {
  $value = [int]$digits
  if ($digits.Length -eq 1) {
    return "$(Convert-NumberToWords $value) $(Get-WordForm $value 'десятая' 'десятых' 'десятых')"
  }
  return "$(Convert-NumberToWords $value) $(Get-WordForm $value 'сотая' 'сотых' 'сотых')"
}

function Convert-DecimalToWords([int]$Whole, [string]$FractionDigits) {
  # 12 и "5" -> "двенадцать целых пять десятых"
  return "$(Convert-NumberToWords $Whole) $(Get-WordForm $Whole 'целая' 'целых' 'целых') $(Convert-FractionToWords $FractionDigits)"
}

function Convert-QuantityToWords([string]$Number, [string]$One, [string]$Few, [string]$Many) {
  # число с единицей: "12.5" + процент -> "двенадцать целых пять десятых процента"
  $whole = [int](($Number -split '[.,]')[0])
  return "$(Convert-AnyNumberToWords $Number) $(Get-WordForm $whole $One $Few $Many)"
}

function Test-DayMonth([int]$Day, [int]$Month) {
  return ($Month -ge 1 -and $Month -le 12 -and $Day -ge 1 -and $Day -le 31)
}

function Convert-AnyNumberToWords([string]$Number) {
  # "12.5" -> "двенадцать целых пять десятых", "1500" -> "тысяча пятьсот"
  $text = $Number.Trim() -replace '\s', ''
  if ($text -match '^(\d+)[.,](\d+)$') {
    return (Convert-DecimalToWords ([int]$Matches[1]) $Matches[2])
  }
  if ($text -match '^\d+$') { return (Convert-NumberToWords ([int]$text)) }
  return $Number
}

function Convert-GroupedNumber([string]$Groups) {
  # "2 500 000" -> "два миллиона пятьсот тысяч"
  $parts = @($Groups -split '\s+')
  $millions = 0; $thousands = 0; $rest = 0
  $count = $parts.Count
  if ($count -ge 3) { $millions = [int]$parts[$count - 3] }
  if ($count -ge 2) { $thousands = [int]$parts[$count - 2] }
  $rest = [int]$parts[$count - 1]
  $out = @(Get-ScaleParts $millions $thousands)
  if ($rest -gt 0 -or -not $out.Count) { $out += (Convert-NumberToWords $rest) }
  return ($out -join ' ')
}

$script:MonthNames = @('января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря')

# --- словарь произношения -------------------------------------------------
# Поддерживаются два формата:
#   pronounce.json    — {"API": "АПИ", "OpenRouter": "Опен Роутер"}
#   pronounce.lexicon — "API<TAB>АПИ" (формат лексикона CMUdict/LEXICON)
# Значение может начинаться с "ipa:" — тогда это фонетическая запись (SSML <phoneme>)
# или с "en:" — читать по-английски (SSML <lang xml:lang="en-US">).

function Get-PronounceMap {
  $map = @{}
  $root = $script:TtsRoot
  $jsonPath = Join-Path $root 'pronounce.json'
  if (Test-Path $jsonPath) {
    try {
      $loaded = Get-Content $jsonPath -Raw | ConvertFrom-Json -AsHashtable
      foreach ($key in $loaded.Keys) { $map[[string]$key] = [string]$loaded[$key] }
    } catch { Write-Log "словарь: pronounce.json не прочитан ($($_.Exception.Message))" }
  }
  $lexPath = Join-Path $root 'pronounce.lexicon'
  if (Test-Path $lexPath) {
    try {
      foreach ($line in Get-Content $lexPath) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $parts = $text -split "`t|=>|\s{2,}", 2
        if ($parts.Count -ge 2 -and $parts[0].Trim()) {
          $map[$parts[0].Trim()] = $parts[1].Trim()
        }
      }
    } catch { Write-Log "словарь: pronounce.lexicon не прочитан ($($_.Exception.Message))" }
  }
  return $map
}

function Get-DefaultPronounceMap {
  return @{
    'API' = 'АПИ'
    'API''s' = 'АПАЙ'
    'OpenRouter' = 'Опен Роутер'
    'GitHub' = 'ГитХаб'
    'Docker' = 'Докер'
    'Linux' = 'Линукс'
    'Windows' = 'Виндоуз'
    'JSON' = 'Джейсон'
    'YAML' = 'Ямл'
    'SQL' = 'Эс Кью Эл'
    'CSS' = 'Си Эс Эс'
    'URL' = 'Юрл'
    'HTTP' = 'Эйч Ти Ти Пи'
    'GPU' = 'Джи Пи Ю'
    'CPU' = 'Си Пи Ю'
    'т.е.' = 'то есть'
    'т.д.' = 'так далее'
    'и т.д.' = 'и так далее'
    'и т.п.' = 'и так прочее'
    'т.п.' = 'так прочее'
    'т.к.' = 'так как'
    'т.о.' = 'таким образом'
    'см.' = 'смотри'
    'стр.' = 'страница'
    'рис.' = 'рисунок'
    'кв.' = 'квадрат'
    'др.' = 'другой'
    'млрд' = 'миллиардов'
    'млн' = 'миллионов'
    'тыс.' = 'тысяч'
  }
}

function Save-DefaultPronounce {
  $path = Join-Path $script:TtsRoot 'pronounce.json'
  if (Test-Path $path) { return }
  try {
    (Get-DefaultPronounceMap | ConvertTo-Json -Depth 3) | Set-Content -Path $path -Encoding utf8
  } catch { }
}

# --- разбор чисел, дат и денег ---------------------------------------------

function Convert-SpeechText([string]$Text, [hashtable]$Pronounce, [bool]$ReadNumbers) {
  if (-not $Text) { return $Text }

  if ($ReadNumbers) {
    # версии: Python 3.11, версия 1.2.3 → числа через «точка» (иначе читаются как дата или дробь)
    $Text = [regex]::Replace($Text, '(?:(?<=[A-Za-z]\s)|(?<pre>(?<=[A-Za-z]))|(?<=верси[яией]\s))\d+(?:\.\d+)+(?![\d.]*\d)(?!\.\d)', {
      param($m)
      $words = (($m.Value -split '\.') | ForEach-Object { Convert-NumberToWords ([int]$_) }) -join ' точка '
      if ($m.Groups['pre'].Success) { return " $words" }
      return $words
    })
    # даты: 16.10.2026 и 16.10 (месяц — всегда две цифры, иначе путается с дробью)
    $Text = [regex]::Replace($Text, '\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b', {
      param($m)
      $day = [int]$m.Groups[1].Value; $month = [int]$m.Groups[2].Value; $year = [int]$m.Groups[3].Value
      if (-not (Test-DayMonth $day $month)) { return $m.Value }
      return "$(Convert-DayToGenitive $day) $($script:MonthNames[$month - 1]) $(Convert-YearToWords $year)"
    })
    $Text = [regex]::Replace($Text, '(?<![\d.])\b(\d{1,2})\.(\d{2})\b(?!\d|\.\d)', {
      param($m)
      $day = [int]$m.Groups[1].Value; $month = [int]$m.Groups[2].Value
      if (-not (Test-DayMonth $day $month)) { return $m.Value }
      return "$(Convert-DayToGenitive $day) $($script:MonthNames[$month - 1])"
    })
    # проценты (вместе с дробной частью: 12.5 процента)
    $Text = [regex]::Replace($Text, '(\d+(?:[.,]\d+)?)\s*(?:%|процент\w*)', {
      param($m)
      return (Convert-QuantityToWords $m.Groups[1].Value 'процент' 'процента' 'процентов')
    })
    # доллары
    $Text = [regex]::Replace($Text, '\$\s*(\d+(?:[.,]\d+)?)', {
      param($m)
      return (Convert-QuantityToWords $m.Groups[1].Value 'доллар' 'доллара' 'долларов')
    })
    # рубли
    $Text = [regex]::Replace($Text, '(\d+(?:[.,]\d+)?)\s*(?:₽|руб\.|рублей|рубля|руб)\b', {
      param($m)
      return (Convert-QuantityToWords $m.Groups[1].Value 'рубль' 'рубля' 'рублей')
    })
    # десятичные: 1.5 → одна целая пять десятых (версии вида 1.2.3 не трогаем)
    $Text = [regex]::Replace($Text, '(?<!\.)\b(\d+)[.,](\d{1,2})\b(?!\.?\d)', {
      param($m)
      return (Convert-DecimalToWords ([int]$m.Groups[1].Value) $m.Groups[2].Value)
    })
    $Text = [regex]::Replace($Text, '\b\d{1,3}(?:\s\d{3})+(?!\d)', {
      param($m) (Convert-GroupedNumber $m.Value)
    })
  }

  # словарь: обычные замены (для всех движков)
  if ($Pronounce -and $Pronounce.Count) {
    foreach ($key in ($Pronounce.Keys | Sort-Object { $_.Length } -Descending)) {
      if (-not $key) { continue }
      $value = [string]$Pronounce[$key]
      if ($value.StartsWith('ipa:') -or $value.StartsWith('en:')) { continue }  # это для SSML-режима
      $pattern = [regex]::Escape($key)
      $Text = [regex]::Replace($Text, "(?<![\p{L}\p{N}_])$pattern(?![\p{L}\p{N}_])", { param($m) $value })
    }
  }
  return $Text
}

# --- сборка SSML 1.1 для Edge ----------------------------------------------

function ConvertTo-Ssml {
  param(
    [string]$Text,
    [hashtable]$Pronounce,
    [bool]$EnglishAsEnglish = $true
  )
  # Внутренняя разметка SSML: обёртку <speak><voice><prosody> добавляет сам движок
  if (-not $Text) { return '' }

  $sb = [System.Text.StringBuilder]::new()
  $esc = { param([string]$v) [System.Security.SecurityElement]::Escape($v) }

  # одним проходом по сырому тексту: словарь и английские слова превращаются в разметку,
  # остальное экранируется; готовая разметка повторно не разбирается
  $alternatives = @()
  if ($Pronounce -and $Pronounce.Count) {
    $keys = @($Pronounce.Keys | Where-Object { $_ } | Sort-Object { $_.Length } -Descending)
    if ($keys.Count) { $alternatives += '(?<dict>' + (($keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')' }
  }
  if ($EnglishAsEnglish) { $alternatives += '(?<en>[A-Za-z][A-Za-z0-9''\-\.]*)' }
  $wordPattern = $null
  if ($alternatives.Count) { $wordPattern = '(?<![\p{L}\p{N}_])(?:' + ($alternatives -join '|') + ')(?![\p{L}\p{N}_])' }

  $tokens = [regex]::Split($Text, '(\*\*[^*]+\*\*|\.\.\.|—|--|\n)')
  foreach ($token in $tokens) {
    if (-not $token) { continue }
    if ($token -match '^\*\*(.+)\*\*$') { [void]$sb.Append("<emphasis level='strong'>$(& $esc $Matches[1])</emphasis>"); continue }
    if ($token -eq '...') { [void]$sb.Append("<break time='320ms'/>"); continue }
    if ($token -eq '—' -or $token -eq '--') { [void]$sb.Append("<break time='200ms'/>"); continue }
    if ($token -eq "`n") { [void]$sb.Append("<break time='260ms'/>"); continue }

    if (-not $wordPattern) { [void]$sb.Append((& $esc $token)); continue }
    $pos = 0
    foreach ($m in [regex]::Matches($token, $wordPattern)) {
      if ($m.Index -gt $pos) { [void]$sb.Append((& $esc $token.Substring($pos, $m.Index - $pos))) }
      $pos = $m.Index + $m.Length
      $word = & $esc $m.Value
      if ($m.Groups['dict'].Success) {
        $value = [string]$Pronounce[$m.Value]
        if ($value.StartsWith('ipa:')) {
          [void]$sb.Append("<phoneme alphabet='ipa' ph='$(& $esc $value.Substring(4).Trim())'>$word</phoneme>")
        } elseif ($value.StartsWith('en:')) {
          [void]$sb.Append("<sub alias='$(& $esc $value.Substring(3).Trim())'>$word</sub>")
        } else {
          [void]$sb.Append("<sub alias='$(& $esc $value)'>$word</sub>")
        }
      } else {
        [void]$sb.Append("<lang xml:lang='en-US'>$word</lang>")
      }
    }
    if ($pos -lt $token.Length) { [void]$sb.Append((& $esc $token.Substring($pos))) }
  }

  return $sb.ToString()
}
