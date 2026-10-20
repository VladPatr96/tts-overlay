# Pester (3.x и новее): pwsh -Command "Invoke-Pester tests"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib-text.ps1')

Describe 'Convert-SpeechText: числа' {
  It 'отдельные целые оставляет движку' { Convert-SpeechText 'Итого 1500' $null $true | Should Be 'Итого 1500' }
  It 'читает рубли с падежом' { Convert-SpeechText '1500 рублей' $null $true | Should Be 'тысяча пятьсот рублей' }
  It 'читает проценты' { Convert-SpeechText '5%' $null $true | Should Be 'пять процентов' }
  It 'читает десятичную дробь' { Convert-SpeechText '1.5' $null $true | Should Be 'один целая пять десятых' }
  It 'читает полную дату' { Convert-SpeechText '16.10.2026' $null $true | Should Be 'шестнадцатого октября две тысячи двадцать шестого года' }
  It 'читает короткую дату' { Convert-SpeechText 'до 16.10' $null $true | Should Be 'до шестнадцатого октября' }
  It 'не трогает числа при выключенном чтении' { Convert-SpeechText '1500' $null $false | Should Be '1500' }
}

Describe 'Convert-SpeechText: тысячи в женском роде' {
  It '2000 — две тысячи' { Convert-SpeechText '2000 рублей' $null $true | Should Be 'две тысячи рублей' }
  It '22000 — двадцать две тысячи' { Convert-SpeechText '22000 рублей' $null $true | Should Be 'двадцать две тысячи рублей' }
  It '21000 — двадцать одна тысяча' { Convert-SpeechText '21000 руб' $null $true | Should Be 'двадцать одна тысяча рублей' }
  It '102000 — сто две тысячи' { Convert-SpeechText '102000 рублей' $null $true | Should Be 'сто две тысячи рублей' }
  It '12000 — двенадцать тысяч (не «две»)' { Convert-SpeechText '12000 рублей' $null $true | Should Be 'двенадцать тысяч рублей' }
  It 'число с пробелами: 22 000' { Convert-SpeechText '22 000 человек' $null $true | Should Be 'двадцать две тысячи человек' }
  It '5000 и 1000 не меняются' {
    Convert-SpeechText '5000 рублей' $null $true | Should Be 'пять тысяч рублей'
    Convert-SpeechText '1000 рублей' $null $true | Should Be 'тысяча рублей'
  }
  It 'тысячи вместе с остатком' { Convert-SpeechText '2002 рубля' $null $true | Should Be 'две тысячи два рубля' }
  It 'миллионы остаются в мужском роде' { Convert-SpeechText '2000000 рублей' $null $true | Should Be 'два миллиона рублей' }
}

Describe 'Convert-SpeechText: дни месяца 21–31' {
  It '21.10 — двадцать первого' { Convert-SpeechText 'до 21.10' $null $true | Should Be 'до двадцать первого октября' }
  It '22–29' {
    Convert-SpeechText '22.10' $null $true | Should Be 'двадцать второго октября'
    Convert-SpeechText '25.10' $null $true | Should Be 'двадцать пятого октября'
    Convert-SpeechText '29.10' $null $true | Should Be 'двадцать девятого октября'
  }
  It '30.10 — тридцатого' { Convert-SpeechText '30.10' $null $true | Should Be 'тридцатого октября' }
  It '31.12 — тридцать первого' { Convert-SpeechText '31.12' $null $true | Should Be 'тридцать первого декабря' }
  It 'дни 1–20 не меняются' {
    Convert-SpeechText '01.10' $null $true | Should Be 'первого октября'
    Convert-SpeechText '19.10' $null $true | Should Be 'девятнадцатого октября'
    Convert-SpeechText '20.10' $null $true | Should Be 'двадцатого октября'
  }
  It 'полная дата с 21-м числом' { Convert-SpeechText '21.10.2026' $null $true | Should Be 'двадцать первого октября две тысячи двадцать шестого года' }
}

Describe 'Convert-SpeechText: годы с круглыми десятками' {
  $cases = @(
    @{ y = 2020; w = 'двадцатого' }, @{ y = 2030; w = 'тридцатого' }, @{ y = 2040; w = 'сорокового' },
    @{ y = 2050; w = 'пятидесятого' }, @{ y = 2060; w = 'шестидесятого' }, @{ y = 2070; w = 'семидесятого' },
    @{ y = 2080; w = 'восьмидесятого' }, @{ y = 2090; w = 'девяностого' }
  )
  foreach ($c in $cases) {
    It "$($c.y) — две тысячи $($c.w) года" {
      Convert-SpeechText "01.01.$($c.y)" $null $true | Should Be "первого января две тысячи $($c.w) года"
    }
  }
  It 'годы с некруглыми десятками не меняются' {
    Convert-SpeechText '01.01.2026' $null $true | Should Be 'первого января две тысячи двадцать шестого года'
    Convert-SpeechText '01.01.2011' $null $true | Should Be 'первого января две тысячи одиннадцатого года'
    Convert-SpeechText '01.01.2019' $null $true | Should Be 'первого января две тысячи девятнадцатого года'
    Convert-SpeechText '01.01.2021' $null $true | Should Be 'первого января две тысячи двадцать первого года'
  }
  It 'полная дата из проверки после правки' {
    Convert-SpeechText '16.10.2026' $null $true | Should Be 'шестнадцатого октября две тысячи двадцать шестого года'
  }
}

Describe 'Convert-SpeechText: сотни в годах' {
  It '1996 — девятьсот в именительном' { Convert-SpeechText '01.01.1996' $null $true | Should Be 'первого января тысяча девятьсот девяносто шестого года' }
  It '1812 — восемьсот' { Convert-SpeechText '01.01.1812' $null $true | Should Be 'первого января тысяча восемьсот двенадцатого года' }
  It '1945 — девятьсот сорок пятого' { Convert-SpeechText '01.01.1945' $null $true | Should Be 'первого января тысяча девятьсот сорок пятого года' }
  It '1990 — сочетание с круглым десятком' { Convert-SpeechText '01.01.1990' $null $true | Should Be 'первого января тысяча девятьсот девяностого года' }
  It '1900 — порядковая форма сотен' { Convert-SpeechText '01.01.1900' $null $true | Should Be 'первого января тысяча девятисотого года' }
  It '1800 — восьмисотого' { Convert-SpeechText '01.01.1800' $null $true | Should Be 'первого января тысяча восьмисотого года' }
  It '2100 — сотого' { Convert-SpeechText '01.01.2100' $null $true | Should Be 'первого января две тысячи сотого года' }
  It 'годы без сотен не меняются' {
    Convert-SpeechText '01.01.2026' $null $true | Should Be 'первого января две тысячи двадцать шестого года'
    Convert-SpeechText '01.01.1099' $null $true | Should Be 'первого января тысяча девяносто девятого года'
  }
  It 'полная дата из проверки после правки' {
    Convert-SpeechText '16.10.2026' $null $true | Should Be 'шестнадцатого октября две тысячи двадцать шестого года'
  }
}

Describe 'Convert-SpeechText: версии не читаются как даты' {
  It 'Python 3.11' { Convert-SpeechText 'Python 3.11' $null $true | Should Be 'Python три точка одиннадцать' }
  It 'версия 1.2.3' { Convert-SpeechText 'версия 1.2.3' $null $true | Should Be 'версия один точка два точка три' }
  It 'v3.11' { Convert-SpeechText 'v3.11' $null $true | Should Be 'v три точка одиннадцать' }
  It 'дата рядом с версией остаётся датой' { Convert-SpeechText '16.10.2026 Python 3.11' $null $true | Should Match '^шестнадцатого октября .* года Python три точка одиннадцать$' }
}

Describe 'Convert-SpeechText: словарь' {
  It 'заменяет слово целиком' { Convert-SpeechText 'API и APIs' @{ 'API' = 'АПИ' } $false | Should Be 'АПИ и APIs' }
}

Describe 'ConvertTo-Ssml' {
  It '**слово** озвучивается один раз' {
    $r = ConvertTo-Ssml '**важно**' @{} $false
    $r | Should Be "<emphasis level='strong'>важно</emphasis>"
  }
  It 'паузы по многоточию, тире и переводу строки' {
    ConvertTo-Ssml "а...б — в`nг" @{} $false | Should Be "а<break time='320ms'/>б <break time='200ms'/> в<break time='260ms'/>г"
  }
  It 'словарь: sub alias' {
    ConvertTo-Ssml 'API' @{ 'API' = 'АПИ' } $false | Should Be "<sub alias='АПИ'>API</sub>"
  }
  It 'словарь: ipa' {
    ConvertTo-Ssml 'Linux' @{ 'Linux' = "ipa:lˈɪnʊks" } $false | Should Be "<phoneme alphabet='ipa' ph='lˈɪnʊks'>Linux</phoneme>"
  }
  It 'экранирует спецсимволы в тексте и значениях словаря' {
    $r = ConvertTo-Ssml 'R&D <b> API' @{ 'API' = "А'П&И" } $false
    $r | Should Be "R&amp;D &lt;b&gt; <sub alias='А&apos;П&amp;И'>API</sub>"
  }
  It 'английские слова не ломают разметку словаря' {
    $r = ConvertTo-Ssml 'use API now' @{ 'API' = 'АПИ' } $true
    $r | Should Be "<lang xml:lang='en-US'>use</lang> <sub alias='АПИ'>API</sub> <lang xml:lang='en-US'>now</lang>"
  }
  It 'результат — well-formed XML' {
    $r = ConvertTo-Ssml "**Привет** & API's — 'ok' <x>...`nDocker" @{ 'API' = 'АПИ'; 'Docker' = "ipa:dˈɒkə'" } $true
    { [xml]"<root xmlns:xml='http://www.w3.org/XML/1998/namespace'>$r</root>" } | Should Not Throw
  }
}
