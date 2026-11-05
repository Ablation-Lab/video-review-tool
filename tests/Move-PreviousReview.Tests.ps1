<#
  Tests for Move-PreviousReview in skills\video-review-skill\review-checks.ps1: each run keeps the
  last review in <OutDir>\previous, and only the files the tool wrote are moved or deleted.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Move-PreviousReview.Tests.ps1
  Exit code 0 means every check passed. No network, no Pester, no ffmpeg needed.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skills\video-review-skill\review-checks.ps1')

$script:Failed = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" } else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:Failed++ }
}
function Put([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $text)
}
function Text([string]$path) { if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { $null } }

# What one run of the tool writes in its output folder, tagged with the run's name.
function New-FakeRun([string]$outDir, [string]$run, [string]$base = 'clip') {
    Put (Join-Path $outDir 'review.json') ("{`"tool`":`"video-review`",`"source`":`"$base.mp4`",`"baseName`":`"$base`",`"mode`":`"video`",`"run`":`"$run`"}")
    Put (Join-Path $outDir 'report.md') $run
    Put (Join-Path $outDir "$base-review.pdf") $run
    Put (Join-Path $outDir "$base-changes.pdf") $run
    Put (Join-Path $outDir 'key-frames.pdf') $run
    Put (Join-Path $outDir 'frames\0001_00-00-00.000_scene.png') $run
    Put (Join-Path $outDir 'frames\0002_00-00-02.000_interval.png') $run
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('video-review-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    # A folder the user picked with -OutDir, which already holds files of theirs.
    $out = Join-Path $root 'Documents'
    Put (Join-Path $out 'invoice.pdf') 'user'
    Put (Join-Path $out 'annual-review.pdf') 'user'
    Put (Join-Path $out 'notes.txt') 'user'
    Put (Join-Path $out 'frames\holiday.png') 'user'
    $prev = Join-Path $out 'previous'

    Write-Host 'Run 1 finishes, run 2 starts (first rotation)'
    New-FakeRun $out 'run1'
    $r = Move-PreviousReview $out
    Check ($r -eq $prev) 'returns <OutDir>\previous'
    Check ((Text (Join-Path $prev 'clip-review.pdf')) -eq 'run1') "the tool's review PDF moved to previous"
    Check ((Text (Join-Path $prev 'clip-changes.pdf')) -eq 'run1') "the tool's changes PDF moved to previous"
    Check ((Text (Join-Path $prev 'key-frames.pdf')) -eq 'run1') 'key-frames.pdf moved to previous'
    Check ((Text (Join-Path $prev 'review.json')) -match 'run1') 'review.json moved to previous'
    Check ((Text (Join-Path $prev 'report.md')) -eq 'run1') 'report.md moved to previous'
    Check ((Text (Join-Path $prev 'frames\0001_00-00-00.000_scene.png')) -eq 'run1') 'frames moved to previous\frames'
    Check (-not (Test-Path (Join-Path $out 'clip-review.pdf'))) 'no review PDF left in the output folder'
    Check ((Text (Join-Path $out 'invoice.pdf')) -eq 'user') "the user's invoice.pdf stays where it was"
    Check ((Text (Join-Path $out 'annual-review.pdf')) -eq 'user') "the user's annual-review.pdf stays where it was"
    Check ((Text (Join-Path $out 'notes.txt')) -eq 'user') "the user's notes.txt stays where it was"
    Check ((Text (Join-Path $out 'frames\holiday.png')) -eq 'user') "the user's frames\holiday.png stays where it was"
    Check (-not (Test-Path (Join-Path $prev 'invoice.pdf'))) "the user's PDF isn't copied into previous"

    # The user also puts a file of their own in previous\ and previous\frames\.
    Put (Join-Path $prev 'keep-me.txt') 'user'
    Put (Join-Path $prev 'frames\keep-me.png') 'user'

    Write-Host 'Run 2 finishes, run 3 starts (the run-1 copy is replaced)'
    New-FakeRun $out 'run2'
    $null = Move-PreviousReview $out
    Check ((Text (Join-Path $prev 'clip-review.pdf')) -eq 'run2') 'previous now holds run 2'
    Check ((Text (Join-Path $prev 'frames\0001_00-00-00.000_scene.png')) -eq 'run2') 'previous\frames now holds run 2'
    Check ((Text (Join-Path $prev 'keep-me.txt')) -eq 'user') "the user's file in previous\ survives"
    Check ((Text (Join-Path $prev 'frames\keep-me.png')) -eq 'user') "the user's file in previous\frames\ survives"
    Check ((Text (Join-Path $out 'invoice.pdf')) -eq 'user') "the user's invoice.pdf is still there"

    Write-Host 'Run 3 finishes, run 4 starts (a run of a different video in the same folder)'
    New-FakeRun $out 'run3' 'other'
    $null = Move-PreviousReview $out
    Check ((Text (Join-Path $prev 'other-review.pdf')) -eq 'run3') "previous holds the other video's PDF"
    Check (-not (Test-Path (Join-Path $prev 'clip-review.pdf'))) "the run-2 PDF in previous was deleted"
    Check ((Text (Join-Path $prev 'keep-me.txt')) -eq 'user') "the user's file in previous\ still survives"
    foreach ($f in 'invoice.pdf', 'annual-review.pdf', 'notes.txt', 'frames\holiday.png') {
        Check ((Text (Join-Path $out $f)) -eq 'user') "after three rotations, the user's $f is untouched"
    }

    Write-Host 'Older review.json files without baseName'
    $old = Join-Path $root 'old-video'
    Put (Join-Path $old 'review.json') '{"source":"My clip.mp4","mode":"video"}'
    Check ((Get-ReviewFileNames $old) -contains 'My clip-review.pdf') 'video: the name comes from the file name'
    $rem = Join-Path $root 'old-remotion'
    Put (Join-Path $rem 'review.json') '{"source":"Main (my-project)","mode":"remotion"}'
    Check ((Get-ReviewFileNames $rem) -contains 'Main-changes.pdf') 'Remotion: the name comes from the composition ID'
    $bad = Join-Path $root 'broken'
    Put (Join-Path $bad 'review.json') 'not json'
    $names = @(Get-ReviewFileNames $bad)
    Check (($names -join ',') -eq 'report.md,review.json,key-frames.pdf') 'unreadable review.json: only the fixed names'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed) { Write-Host "$script:Failed check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
