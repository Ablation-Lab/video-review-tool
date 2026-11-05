<#
.SYNOPSIS
    Makes Cutproof's sample video, so you can try a review straight away.

.DESCRIPTION
    Writes cutproof-sample.mp4 next to this script: 6 seconds of plain text on a dark background,
    made from scratch with ffmpeg (no audio and no copyrighted material). It has two slides:

      0-3 s  "Welcome to the Cutproof sampel"   (a deliberate typo: "sampel")
      3-6 s  "Sales grew 25% this year"          (the narration says 35%)

    The slides' text, timing and style are in cutproof-sample-slides.ass, a text subtitle file
    that ffmpeg's ass filter draws onto ffmpeg's built-in colour source. It names the Arial font,
    which Windows supplies. cutproof-sample.srt, next to it, is the narration. Cutproof finds it
    because it has the video's name, and should flag both problems. expected-results.md says what
    to look for.

    It runs one fixed ffmpeg command, reads only cutproof-sample-slides.ass and makes no network
    requests.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\samples\make-sample.ps1
#>
$ErrorActionPreference = 'Stop'

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw 'ffmpeg was not found. Install it first (see Requirements in the README).'
}

# The command is fixed. It runs in this folder, so the file names need no paths.
Push-Location -LiteralPath $PSScriptRoot
try {
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=0x14202e:s=960x540:r=25:d=6' `
        -vf 'ass=cutproof-sample-slides.ass' -c:v libx264 -preset veryslow -crf 30 -tune stillimage `
        -pix_fmt yuv420p -movflags +faststart 'cutproof-sample.mp4'
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed (exit $LASTEXITCODE)." }
    $video = (Get-Item -LiteralPath 'cutproof-sample.mp4').FullName
} finally {
    Pop-Location
}

Write-Host "Made $video ($([math]::Round((Get-Item -LiteralPath $video).Length / 1KB)) KB)."
Write-Host 'Now ask Claude Code: "Do a full review of' $video'"'
