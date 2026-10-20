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
