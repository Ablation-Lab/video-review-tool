<#
.SYNOPSIS
    Makes Cutproof's sample video, so you can try a review straight away.

.DESCRIPTION
    Writes cutproof-sample.mp4 next to this script: 6 seconds of plain text on a dark background,
    made from scratch with ffmpeg (no audio and no copyrighted material). It has two slides:

      0-3 s  "Welcome to the Cutproof sampel"   (a deliberate typo: "sampel")
      3-6 s  "Sales grew 25% this year"          (the narration says 35%)

    cutproof-sample.srt, next to it, is the narration. Cutproof finds it because it has the
    video's name, and should flag both problems. expected-results.md says what to look for.

    It only runs ffmpeg from your PATH with ffmpeg's built-in colour source and the Arial Bold
    font that comes with Windows. It reads nothing else and makes no network requests.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\samples\make-sample.ps1
#>
[CmdletBinding()]
param(
    # Where to write the video. Default: cutproof-sample.mp4 next to this script.
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 doesn't set $PSScriptRoot in parameter defaults, so it's filled in here.
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'cutproof-sample.mp4' }

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw 'ffmpeg was not found on PATH. Install it first (see Requirements in the README).'
}
$font = Join-Path $env:WINDIR 'Fonts\arialbd.ttf'
if (-not (Test-Path -LiteralPath $font)) { throw "The Arial Bold font wasn't found at $font." }
# ffmpeg filter syntax: forward slashes, and the drive colon escaped.
$fontArg = ($font -replace '\\', '/') -replace ':', '\:'

function Get-Slide([string]$Text, [string]$When) {
    "drawtext=fontfile='$fontArg':expansion=none:text='$Text':fontcolor=white:fontsize=56:" +
    "x=(w-text_w)/2:y=(h-text_h)/2:enable='$When'"
}
$filter = (Get-Slide 'Welcome to the Cutproof sampel' 'lt(t,3)') + ',' +
          (Get-Slide 'Sales grew 25% this year' 'gte(t,3)')

& ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=0x14202e:s=960x540:r=25:d=6' `
    -vf $filter -c:v libx264 -preset veryslow -crf 30 -tune stillimage -pix_fmt yuv420p `
    -movflags +faststart $OutFile
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed (exit $LASTEXITCODE)." }

Write-Host "Made $OutFile ($([math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB)) KB)."
Write-Host 'Now ask Claude Code: "Do a full review of' $OutFile'"'
