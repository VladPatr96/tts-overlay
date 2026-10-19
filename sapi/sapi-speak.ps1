param(
  [Parameter(Mandatory = $true)][string]$TextFile,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [string]$Voice = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

$synth = [System.Speech.Synthesis.SpeechSynthesizer]::new()
if ($Voice) {
  foreach ($v in $synth.GetInstalledVoices()) {
    if ($v.VoiceInfo.Name -like "*$Voice*") { $synth.SelectVoice($v.VoiceInfo.Name); break }
  }
}
$text = [System.IO.File]::ReadAllText($TextFile)
$synth.SetOutputToWaveFile($OutFile)
$synth.Speak($text)
$synth.SetOutputToNull()
$synth.Dispose()
