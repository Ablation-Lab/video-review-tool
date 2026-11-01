<#
.SYNOPSIS
  Builds a review pack for a rendered video or a Remotion project, so an AI can check the video
  without watching it: still frames, audio findings, report.md and a PDF contact sheet.

.DESCRIPTION
  Video file (MP4 or anything ffmpeg reads):
    - a frame at every scene change, one every -Interval seconds and the last frame, saved as
      numbered PNGs with the timestamp in the file name;
    - audio checks: length, loudness (LUFS), peaks, clipping, silences longer than -MinSilence
      seconds and sudden clicks or pops, all with timestamps;
    - the narration line spoken at each frame, when a narration script, recording table,
      voiceover.json or subtitle file can be found and matched to the audio;
    - the text on screen in every frame (Windows' built-in OCR), with checks for spelling,
      reading time, spoken numbers missing from the screen and YouTube Shorts safe areas;
    - what changed since the previous review of the same video (kept in <OutDir>\previous);
    - report.md (for Claude Code: open it with the frames) and a PDF (to attach to a chat).
  Remotion project folder: renders stills at chosen frames with npx remotion still (no full render
  needed) and, unless -NoAudio, renders the audio track alone for the same checks.

.EXAMPLE
  .\review-video.ps1 .\out\explainer.mp4

.EXAMPLE
  .\review-video.ps1 ..\my-remotion-project -Composition Main -Frames 0,90,450

.LINK
  SKILL.md in this folder (how Claude uses the tool), and README.md at the root of the
  video-review-tool repository.
#>
[CmdletBinding()]
param(
    # A video file, or a Remotion project folder.
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    # Where the review pack goes. Default: "<video name>-review" next to the video, or
    # "out\<composition>-review" inside a Remotion project.
    [string]$OutDir,

    # Seconds between regular frames.
    [double]$Interval = 2,

    # Scene-change sensitivity (ffmpeg scene score between frames 0.25 s apart). The default suits
    # slides and motion graphics with fades; use about 0.3 for camera footage.
    [double]$SceneThreshold = 0.02,

    # Audio below this level counts as silence (dBFS).
    [double]$SilenceDb = -50,

    # Report silences at least this long (seconds).
    [double]$MinSilence = 1.5,

    # A click is a jump at least this many times larger than the signal in the 2 ms around it...
    [double]$ClickRatio = 20,

    # ...and at least this loud (dBFS). Lower both to catch quieter clicks (and more false alarms).
    [double]$ClickMinDb = -45,

    # Samples at or above this level count as clipped (dBFS).
    [double]$ClipDb = -0.1,

    # Narration source file: .srt, .vtt, .csv, .tsv, .md (recording table, timed table or "> " lines)
    # or a voiceover.json. Default: found automatically (see README).
    [string]$Narration,

    # Folder to search for narration. Default: the Remotion project, or the nearest folder above the
    # video that holds package.json, script.md or src\voiceover.json.
    [string]$Project,

    # Remotion only: composition ID. Default: the first one listed.
    [string]$Composition,

    # Remotion only: frame numbers to render, e.g. 0,90,450. Default: one every -Interval seconds
    # plus the last frame.
    [string[]]$Frames,

    # Remotion only: skip rendering the audio (no audio checks or narration matching).
    [switch]$NoAudio,

    # Size limit for the PDF in MB. Frames are made smaller until it fits.
    [double]$MaxPdfMB = 20,

    # Skip the PDF.
    [switch]$NoPdf,

    # Skip reading on-screen text (OCR) and the checks that use it: spelling, reading time, numbers
    # and safe areas.
    [switch]$NoOcr,

    # Language for OCR and spelling, e.g. en-US. Default: your Windows language.
    [string]$OcrLanguage,

    # Text file of extra words the spelling check accepts, one per line. review-words.txt in the
    # project folder is read automatically too.
    [string]$WordList,

    # Reading speed for the reading-time check, in words per second.
    [double]$WordsPerSecond = 3,

    # Numbers spoken as words are checked from this value up (5 and "five" are often said without
    # being shown). Numbers written as digits in the narration are always checked.
    [double]$NumberWordsFrom = 10,

    # YouTube Shorts safe-area margins in pixels at 1080x1920: top,right,bottom,left. The default is
    # Google's Universal Video Ad Safe Zones for vertical video.
    [string]$SafeMargins = '288,192,672,48',

    # A previous review folder to compare with. Default: the last run of this review, which is kept
    # in <OutDir>\previous.
    [string]$CompareWith,

    # Also make a PDF of only the frames that changed since the previous review.
    [switch]$ChangesPdf,

    # Keep the temporary _work folder (for debugging).
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$script:OldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Utf8 = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Add-Warning([string]$msg) { $script:Warnings.Add($msg); Write-Host "WARNING: $msg" -ForegroundColor Yellow }

function Format-Time([double]$t) {
    # 83.456 -> 01:23.46, 3725.1 -> 1:02:05.10
    $t = [Math]::Round([Math]::Max($t, 0), 2)
    $h = [Math]::Floor($t / 3600); $m = [Math]::Floor(($t - $h * 3600) / 60); $s = $t - $h * 3600 - $m * 60
    if ($h -gt 0) { return '{0}:{1:00}:{2:00.00}' -f $h, $m, $s }
    return '{0:00}:{1:00.00}' -f $m, $s
}

function Format-Stamp([double]$t) {
    # For file names: 83.456 -> 00-01-23.456
    $t = [Math]::Round([Math]::Max($t, 0), 3)
    $h = [Math]::Floor($t / 3600); $m = [Math]::Floor(($t - $h * 3600) / 60); $s = $t - $h * 3600 - $m * 60
    return '{0:00}-{1:00}-{2:00.000}' -f $h, $m, $s
}

function Format-Db($v, [string]$unit = 'dBFS') {
    if ($null -eq $v -or [double]::IsNegativeInfinity([double]$v)) { return "-inf $unit" }
    return '{0:0.0} {1}' -f [double]$v, $unit
}

function ConvertFrom-TimeString([string]$s) {
    # Accepts 83.4, 1:23.4, 01:23:45,600, 00:01:23.400
    $s = $s.Trim().Trim('`').Replace(',', '.')
    if ($s -match '^\d+(\.\d+)?$') { return [double]$s }
    if ($s -match '^(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)$') {
        $h = 0; if ($Matches[1]) { $h = [double]$Matches[1] }
        return $h * 3600 + [double]$Matches[2] * 60 + [double]$Matches[3]
    }
    return $null
}

function ConvertTo-Arg([string]$a) {
    # Quotes one argument for ProcessStartInfo.Arguments (Windows command-line rules).
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"'); $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    [void]$sb.Append('\' * ($bs * 2)); [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Tool {
    # Runs a program, captures its output and throws with the program's own error text if it fails.
    param([string]$Exe, [string[]]$ArgList, [string]$What, [string]$WorkDir, [switch]$AllowFail, [switch]$NoCapture)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($ArgList) | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    if ($NoCapture) {
        # For the browser: its helper processes can outlive it and keep captured pipes open.
        $psi.CreateNoWindow = $true
        try { $p = [System.Diagnostics.Process]::Start($psi) } catch { throw "$What`: could not start $Exe ($($_.Exception.Message))" }
        $p.WaitForExit()
        return [pscustomobject]@{ Code = $p.ExitCode; Out = ''; Err = '' }
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { throw "$What`: could not start $Exe ($($_.Exception.Message))" }
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $r = [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result; Err = $e.Result }
    if ($r.Code -ne 0 -and -not $AllowFail) {
        $esc = [char]27
        $tail = (($r.Err + "`n" + $r.Out) -split "`r?`n" | ForEach-Object { $_ -replace "$esc\[[0-9;]*m", '' } |
                Where-Object { $_.Trim() } | Select-Object -Last 15) -join "`n"
        throw "$What failed (exit code $($r.Code)):`n$tail"
    }
    return $r
}

function Get-ToolPath([string]$name) {
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Write-Utf8([string]$file, [string]$text) { [IO.File]::WriteAllText($file, $text, $script:Utf8) }

function Get-Md([string]$s) {
    # Text safe inside a Markdown table cell.
    if ($null -eq $s) { return '' }
    return ($s -replace '\|', '\|' -replace "`r?`n", ' ')
}

function Get-Html([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }

# ---------------------------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------------------------

function Assert-Ffmpeg {
    $script:Ffmpeg = Get-ToolPath 'ffmpeg'
    $script:Ffprobe = Get-ToolPath 'ffprobe'
    if (-not $script:Ffmpeg -or -not $script:Ffprobe) {
        $missing = @(); if (-not $script:Ffmpeg) { $missing += 'ffmpeg' }; if (-not $script:Ffprobe) { $missing += 'ffprobe' }
        throw @"
$($missing -join ' and ') not found on PATH. Install ffmpeg (it includes ffprobe) with one of:
    winget install --id Gyan.FFmpeg -e
    choco install ffmpeg
or download a build from https://www.gyan.dev/ffmpeg/builds/ and add its bin folder to PATH.
Then open a new PowerShell window (so PATH is reloaded) and run this script again.
"@
    }
    $v = (Invoke-Tool $script:Ffmpeg @('-hide_banner', '-version') 'ffmpeg -version').Out
    $script:FfmpegVersion = (($v -split "`r?`n")[0] -replace '^ffmpeg version (\S+).*', '$1')
}

function Find-Browser {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    foreach ($n in 'msedge', 'chrome') { $p = Get-ToolPath $n; if ($p) { return $p } }
    return $null
}

# ---------------------------------------------------------------------------------------------
# Probing and audio checks
# ---------------------------------------------------------------------------------------------

function Get-MediaInfo([string]$file) {
    $r = Invoke-Tool $script:Ffprobe @('-v', 'error', '-show_entries',
        'format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,channels,sample_rate,duration',
        '-of', 'json', $file) "ffprobe on $file"
    $j = $r.Out | ConvertFrom-Json
    $info = [ordered]@{ Duration = 0.0; HasVideo = $false; HasAudio = $false; Width = 0; Height = 0; Fps = 0.0
        VideoCodec = ''; AudioCodec = ''; Channels = 0; SampleRate = 0 }
    if ($j.format -and $j.format.duration) { $info.Duration = [double]$j.format.duration }
    foreach ($s in @($j.streams)) {
        if ($s.codec_type -eq 'video' -and -not $info.HasVideo) {
            $info.HasVideo = $true; $info.Width = [int]$s.width; $info.Height = [int]$s.height; $info.VideoCodec = $s.codec_name
            $rate = $s.avg_frame_rate; if (-not $rate -or $rate -eq '0/0') { $rate = $s.r_frame_rate }
            if ($rate -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -gt 0) { $info.Fps = [double]$Matches[1] / [double]$Matches[2] }
            if ($info.Duration -le 0 -and $s.duration) { $info.Duration = [double]$s.duration }
        }
        if ($s.codec_type -eq 'audio' -and -not $info.HasAudio) {
            $info.HasAudio = $true; $info.AudioCodec = $s.codec_name; $info.Channels = [int]$s.channels; $info.SampleRate = [int]$s.sample_rate
            if ($info.Duration -le 0 -and $s.duration) { $info.Duration = [double]$s.duration }
        }
    }
    return [pscustomobject]$info
}

function Initialize-AudioScan {
    if (-not ('VideoReview.AudioScan' -as [type])) {
        $cs = Join-Path $PSScriptRoot 'AudioScan.cs'
        if (-not (Test-Path -LiteralPath $cs)) { throw "AudioScan.cs is missing; it must sit next to review-video.ps1 ($cs)." }
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($cs)) -Language CSharp
    }
}

function Invoke-AudioChecks([string]$file, $media) {
    Write-Step 'Audio: loudness, peaks and silences'
    $af = 'ebur128=peak=true+sample,silencedetect=noise={0}dB:d={1}' -f $SilenceDb, $MinSilence
    $r = Invoke-Tool $script:Ffmpeg @('-hide_banner', '-nostdin', '-nostats', '-i', $file, '-vn', '-map', '0:a:0',
        '-af', $af, '-f', 'null', '-') 'loudness and silence scan'
    $log = $r.Err
    $a = [ordered]@{ Integrated = $null; Lra = $null; TruePeak = $null; SamplePeakEbu = $null; Silences = @() }
    $sum = $log.Substring([Math]::Max(0, $log.LastIndexOf('Summary:')))
    if ($sum -match 'I:\s*(-?[\d.]+|-inf) LUFS') { $a.Integrated = [double]($Matches[1] -replace '-inf', '-Infinity') }
    if ($sum -match 'LRA:\s*([\d.]+) LU') { $a.Lra = [double]$Matches[1] }
    if ($sum -match 'Sample peak:\s*Peak:\s*(-?[\d.]+|-inf)') { $a.SamplePeakEbu = [double]($Matches[1] -replace '-inf', '-Infinity') }
    if ($sum -match 'True peak:\s*Peak:\s*(-?[\d.]+|-inf)') { $a.TruePeak = [double]($Matches[1] -replace '-inf', '-Infinity') }
    if ($null -eq $a.Integrated) { throw "Could not read the loudness summary from ffmpeg's ebur128 output." }

    $sil = New-Object System.Collections.Generic.List[object]
    $open = $null
    foreach ($line in ($log -split "`r?`n")) {
        if ($line -match 'silence_start:\s*(-?[\d.e+-]+)') { $open = [Math]::Max(0, [double]$Matches[1]) }
        elseif ($line -match 'silence_end:\s*([\d.e+-]+)\s*\|\s*silence_duration:\s*([\d.e+-]+)') {
            $end = [double]$Matches[1]; $start = if ($null -ne $open) { $open } else { $end - [double]$Matches[2] }
            $sil.Add([pscustomobject]@{ Start = $start; End = $end; Length = $end - $start }); $open = $null
        }
    }
    if ($null -ne $open) { $sil.Add([pscustomobject]@{ Start = $open; End = $media.Duration; Length = $media.Duration - $open }) }
    $a.Silences = @($sil | Where-Object { $_.Length -ge $MinSilence - 0.001 })

    Write-Step 'Audio: sample scan for clicks, pops and clipping'
    Initialize-AudioScan
    $ch = if ($media.Channels -eq 1) { 1 } else { 2 }
    $scan = [VideoReview.AudioScan]::Analyze($script:Ffmpeg, $file, $ch, $ClickRatio, $ClickMinDb, $ClipDb)
    $a.Scan = $scan
    $a.Length = $scan.Duration

    # Loudest moments: highest 100 ms windows, at least 1 s apart.
    $wins = $scan.WindowPeakDb
    $order = 0..($wins.Length - 1) | Sort-Object { $wins[$_] } -Descending
    $loud = New-Object System.Collections.Generic.List[object]
    foreach ($i in $order) {
        if ([double]::IsNegativeInfinity($wins[$i])) { break }
        $t = $i * 0.1
        if (@($loud | Where-Object { [Math]::Abs($_.Time - $t) -lt 1.0 }).Count -eq 0) { $loud.Add([pscustomobject]@{ Time = $t; Peak = $wins[$i] }) }
        if ($loud.Count -ge 5) { break }
    }
    $a.Loudest = $loud.ToArray()
    $a.Clicks = @($scan.Clicks | Sort-Object Ratio -Descending)
    $a.Clipping = @($scan.Clipping | ForEach-Object { $_ })
    return [pscustomobject]$a
}

# ---------------------------------------------------------------------------------------------
# Narration: find a source, then place each line in time
# ---------------------------------------------------------------------------------------------

function Find-ProjectFolder([string]$start) {
    $d = Get-Item -LiteralPath $start
    for ($i = 0; $i -lt 4 -and $d; $i++) {
        foreach ($marker in 'package.json', 'script.md', 'src\voiceover.json') {
            if (Test-Path -LiteralPath (Join-Path $d.FullName $marker)) { return $d.FullName }
        }
        $d = $d.Parent
    }
    return $null
}

function Get-ProjectFiles([string]$root, [string[]]$extensions, [int]$depth = 4) {
    # Recursive listing that skips dependency, build and output folders.
    $skip = @('node_modules', '.git', 'out', 'build', 'dist', '.remotion', '.next', '_work')
    $result = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($root, 0))
    while ($queue.Count) {
        $item = $queue.Dequeue(); $dir = $item[0]; $lvl = $item[1]
        try { $files = [IO.Directory]::GetFiles($dir); $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($f in $files) {
            if ($extensions -contains [IO.Path]::GetExtension($f).ToLowerInvariant()) { $result.Add($f) }
        }
        if ($lvl -lt $depth) {
            foreach ($sub in $subs) {
                if ($skip -notcontains [IO.Path]::GetFileName($sub)) { $queue.Enqueue(@($sub, $lvl + 1)) }
            }
        }
    }
    return $result.ToArray()
}

function New-Line([string]$text, [string]$clip, [double]$clipStart, [double]$clipLen, $start, $end) {
    return [pscustomobject]@{ Text = $text.Trim(); Clip = $clip; ClipStart = $clipStart; ClipLen = $clipLen
        Start = $start; End = $end; Score = $null }
}

function Read-MdTables([string]$file) {
    # Returns one group per Markdown table that has a file column (recording table) or a time column.
    $groups = @()
    $lines = [IO.File]::ReadAllLines($file)
    $heading = ''
    $rel = [IO.Path]::GetFileName($file)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if ($l -match '^#{1,6}\s+(.*)$') { $heading = $Matches[1].Trim() }
        if ($l -notmatch '^\s*\|' -or $i + 1 -ge $lines.Length -or $lines[$i + 1] -notmatch '^\s*\|[\s:\-|]+\|\s*$') { continue }
        $hdr = @($l.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim().ToLowerInvariant() })
        $fileCol = -1; $textCol = -1; $startCol = -1; $endCol = -1
        for ($c = 0; $c -lt $hdr.Count; $c++) {
            $h = $hdr[$c]
            if ($fileCol -lt 0 -and $h -match '^(file|clip|audio|recording|take)') { $fileCol = $c }
            elseif ($textCol -lt 0 -and $h -match '^(line|text|narration|script|words|voiceover|vo|spoken)') { $textCol = $c }
            elseif ($startCol -lt 0 -and $h -match '^(start|time|timestamp|from|in)\b') { $startCol = $c }
            elseif ($endCol -lt 0 -and $h -match '^(end|to|out)\b') { $endCol = $c }
        }
        $tableLine = $i + 1
        $i += 2
        $rows = @()
        while ($i -lt $lines.Length -and $lines[$i] -match '^\s*\|') {
            $rows += , @($lines[$i].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }); $i++
        }
        $i--
        if ($textCol -lt 0 -or ($fileCol -lt 0 -and $startCol -lt 0)) { continue }
        $items = @()
        foreach ($r in $rows) {
            if ($r.Count -le $textCol) { continue }
            $text = $r[$textCol] -replace '\\\|', '|'
            if ($startCol -ge 0) {
                $st = ConvertFrom-TimeString $r[$startCol]; if ($null -eq $st) { continue }
                $en = $null; if ($endCol -ge 0 -and $r.Count -gt $endCol) { $en = ConvertFrom-TimeString $r[$endCol] }
                $items += New-Line $text $null 0 0 $st $en
            } else {
                $clip = ($r[$fileCol] -replace '[`*]', '').Trim()
                if ($clip) { $items += New-Line $text $clip 0 0 $null $null }
            }
        }
        if ($items.Count) {
            $kind = if ($startCol -ge 0) { 'timed' } else { 'clips' }
            $label = "$rel, table at line $tableLine" + $(if ($heading) { " (under '$heading')" } else { '' })
            $groups += [pscustomobject]@{ Source = $label; Kind = $kind; Lines = $items; Folder = [IO.Path]::GetDirectoryName($file) }
        }
    }
    return $groups
}

function Read-MdQuotes([string]$file) {
    # "> " lines, used only as an untimed list.
    $items = @()
    foreach ($l in [IO.File]::ReadAllLines($file)) {
        if ($l -match '^>\s+(.+)$') { $items += New-Line $Matches[1] $null 0 0 $null $null }
    }
    if ($items.Count) { return [pscustomobject]@{ Source = ([IO.Path]::GetFileName($file) + ' ("> " lines)'); Kind = 'untimed'; Lines = $items; Folder = '' } }
    return $null
}

function Read-Subtitles([string]$file) {
    $text = [IO.File]::ReadAllText($file) -replace "`r", ''
    $items = @()
    foreach ($block in ($text -split "`n\s*`n")) {
        $bl = @($block -split "`n" | Where-Object { $_ -ne '' })
        for ($k = 0; $k -lt $bl.Count; $k++) {
            if ($bl[$k] -match '^\s*([\d:.,]+)\s*-->\s*([\d:.,]+)') {
                $st = ConvertFrom-TimeString $Matches[1]; $en = ConvertFrom-TimeString $Matches[2]
                $t = (($bl[($k + 1)..($bl.Count - 1)] | Where-Object { $_ }) -join ' ') -replace '<[^>]+>', ''
                if ($k + 1 -lt $bl.Count -and $null -ne $st -and $t.Trim()) { $items += New-Line $t $null 0 0 $st $en }
                break
            }
        }
    }
    if (-not $items.Count) { throw "No subtitle cues found in $file." }
    return [pscustomobject]@{ Source = [IO.Path]::GetFileName($file); Kind = 'timed'; Lines = $items; Folder = '' }
}

function Read-CsvNarration([string]$file) {
    $delim = if ($file -match '\.tsv$') { "`t" } else { ',' }
    $rows = @(Import-Csv -LiteralPath $file -Delimiter $delim)
    if (-not $rows.Count) { throw "No rows in $file." }
    $cols = @($rows[0].PSObject.Properties.Name)
    $find = { param($re) $cols | Where-Object { $_.Trim().ToLowerInvariant() -match $re } | Select-Object -First 1 }
    $textCol = & $find '^(line|text|narration|script|words|voiceover|vo|spoken)'
    $startCol = & $find '^(start|time|timestamp|from|in)\b'
    $endCol = & $find '^(end|to|out)\b'
    $fileCol = & $find '^(file|clip|audio|recording|take)'
    if (-not $textCol -or (-not $startCol -and -not $fileCol)) {
        throw "$file needs a text column (line/text/narration) and a start column (start/time) or a file column (file/clip)."
    }
    $items = @()
    foreach ($r in $rows) {
        if ($startCol) {
            $st = ConvertFrom-TimeString ([string]$r.$startCol); if ($null -eq $st) { continue }
            $en = $null; if ($endCol) { $en = ConvertFrom-TimeString ([string]$r.$endCol) }
            $items += New-Line ([string]$r.$textCol) $null 0 0 $st $en
        } else { $items += New-Line ([string]$r.$textCol) ([string]$r.$fileCol) 0 0 $null $null }
    }
    $kind = if ($startCol) { 'timed' } else { 'clips' }
    return [pscustomobject]@{ Source = [IO.Path]::GetFileName($file); Kind = $kind; Lines = $items; Folder = [IO.Path]::GetDirectoryName($file) }
}

function Read-VoiceoverJson([string]$file, [string]$projectRoot) {
    # { "<id>": { "file": "audio/x.mp3", "seconds": 7.5, "words": [ { "text", "startMs", "endMs" } ] } }
    # Each clip is split into sentences (using the word timings) so frames get the sentence being spoken.
    try { $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Add-Warning "Skipped $file`: not valid JSON."; return $null }
    $items = @()
    foreach ($p in $j.PSObject.Properties) {
        $v = $p.Value
        if (-not ($v -is [pscustomobject]) -or -not $v.file) { continue }
        $words = @($v.words)
        if (-not $words.Count -or $null -eq $words[0].startMs) {
            $items += New-Line ([string]$p.Name) $v.file 0 ([double]$v.seconds) $null $null; continue
        }
        $cur = @()
        for ($w = 0; $w -lt $words.Count; $w++) {
            $cur += $words[$w]
            $isEnd = ($words[$w].text -match '[.!?]["'')\]]*$') -or $w -eq $words.Count - 1
            $len = ($cur[-1].endMs - $cur[0].startMs) / 1000.0
            if ($isEnd -and ($len -ge 1.0 -or $w -eq $words.Count - 1)) {
                $items += New-Line (($cur | ForEach-Object { $_.text }) -join ' ') $v.file ($cur[0].startMs / 1000.0) $len $null $null
                $cur = @()
            }
        }
    }
    if (-not $items.Count) { return $null }
    $rel = if ($projectRoot -and $file.StartsWith($projectRoot, [StringComparison]::OrdinalIgnoreCase)) { $file.Substring($projectRoot.Length).TrimStart('\') } else { [IO.Path]::GetFileName($file) }
    return [pscustomobject]@{ Source = $rel; Kind = 'clips'; Lines = $items; Folder = $projectRoot }
}

function Read-NarrationFile([string]$file, [string]$projectRoot) {
    switch -regex ([IO.Path]::GetExtension($file).ToLowerInvariant()) {
        '^\.(srt|vtt)$' { return @(Read-Subtitles $file) }
        '^\.(csv|tsv)$' { return @(Read-CsvNarration $file) }
        '^\.json$' { $g = Read-VoiceoverJson $file $(if ($projectRoot) { $projectRoot } else { [IO.Path]::GetDirectoryName($file) }); if ($g) { return @($g) }; return @() }
        '^\.(md|markdown|txt)$' { $g = @(Read-MdTables $file); $q = Read-MdQuotes $file; if ($q) { $g += $q }; return $g }
        default { throw "Unsupported narration file type: $file (use .srt, .vtt, .csv, .tsv, .md or voiceover.json)." }
    }
}

function Find-NarrationGroups([string]$videoFile, [string]$projectRoot) {
    if ($Narration) {
        $f = (Resolve-Path -LiteralPath $Narration).Path
        $g = @(Read-NarrationFile $f $projectRoot)
        if (-not $g.Count) { throw "No narration lines found in $f." }
        return $g
    }
    $groups = @()
    if ($videoFile) {
        foreach ($ext in '.srt', '.vtt') {
            $side = [IO.Path]::ChangeExtension($videoFile, $ext)
            if (Test-Path -LiteralPath $side) { return @(Read-Subtitles $side) }
        }
    }
    if (-not $projectRoot) { return @() }
    foreach ($md in [IO.Directory]::GetFiles($projectRoot, '*.md')) { $groups += @(Read-MdTables $md) }
    foreach ($js in (Get-ProjectFiles $projectRoot @('.json') 3 | Where-Object { [IO.Path]::GetFileName($_) -ieq 'voiceover.json' })) {
        $g = Read-VoiceoverJson $js $projectRoot; if ($g) { $groups += $g }
    }
    foreach ($sub in (Get-ProjectFiles $projectRoot @('.srt', '.vtt') 1)) { $groups += Read-Subtitles $sub }
    foreach ($md in [IO.Directory]::GetFiles($projectRoot, '*.md')) { $q = Read-MdQuotes $md; if ($q) { $groups += $q } }
    return $groups
}

function Resolve-Clip([string]$clip, [string[]]$roots, [hashtable]$index) {
    if (-not $clip) { return $null }
    if ([IO.Path]::IsPathRooted($clip) -and (Test-Path -LiteralPath $clip)) { return $clip }
    foreach ($r in $roots) {
        if (-not $r) { continue }
        foreach ($c in @((Join-Path $r $clip), (Join-Path $r "public\$clip"), (Join-Path $r "public\audio\$clip"), (Join-Path $r "audio\$clip"))) {
            if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
        }
    }
    $name = [IO.Path]::GetFileName($clip).ToLowerInvariant()
    if ($index.ContainsKey($name)) { return $index[$name] }
    return $null
}

function Invoke-NarrationMatch($groups, [string]$projectRoot, $audio) {
    # Clip-based sources (recording tables, voiceover.json) are placed by matching each clip's
    # loudness envelope (10 ms steps) against the video's audio; the group that matches best wins.
    # Timed sources (subtitles, tables with a start column) are used as they are. A subtitle file
    # next to the video, or a -Narration file, is the only candidate when present.
    $result = [pscustomobject]@{ Group = $null; Lines = @(); Matched = 0; Considered = @(); Note = '' }
    if (-not $groups -or -not @($groups).Count) { $result.Note = 'No narration source found.'; return $result }

    $clipGroups = @($groups | Where-Object { $_.Kind -eq 'clips' })
    if ($clipGroups.Count -and $audio) {
        Write-Step "Narration: matching $($clipGroups.Count) candidate source(s) against the audio"
        $index = @{}
        if ($projectRoot) {
            foreach ($f in (Get-ProjectFiles $projectRoot @('.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac', '.opus') 4)) {
                $n = [IO.Path]::GetFileName($f).ToLowerInvariant(); if (-not $index.ContainsKey($n)) { $index[$n] = $f }
            }
        }
        $video = $audio.Scan.Envelope
        $envCache = @{}
        $best = $null
        foreach ($g in $clipGroups) {
            $lines = @($g.Lines | ForEach-Object { $_.PSObject.Copy() })
            $from = 0; $first = $true; $matched = 0; $missing = 0; $sumScore = 0.0
            foreach ($l in $lines) {
                $path = Resolve-Clip $l.Clip @($g.Folder, $projectRoot) $index
                if (-not $path) { $missing++; continue }
                if ($l.ClipLen -le 0) {
                    if (-not $envCache.ContainsKey("dur|$path")) { $envCache["dur|$path"] = (Get-MediaInfo $path).Duration }
                    $l.ClipLen = $envCache["dur|$path"]
                }
                $len = [Math]::Min($l.ClipLen, 4.0)
                $key = "$path|$($l.ClipStart)|$len"
                if (-not $envCache.ContainsKey($key)) { $envCache[$key] = [VideoReview.AudioScan]::Envelope($script:Ffmpeg, $path, $l.ClipStart, $len) }
                $clipEnv = $envCache[$key]
                $to = if ($first) { $video.Length } else { $from + 9000 + [int]($l.ClipLen * 100) }
                $m = [VideoReview.AudioScan]::FindBest($video, $clipEnv, $from, $to)
                $need = if ($len -lt 0.8) { 0.8 } else { 0.7 }
                if ($m.Index -ge 0 -and $m.Score -ge $need) {
                    $l.Start = $m.Index / 100.0; $l.End = $l.Start + $l.ClipLen; $l.Score = $m.Score
                    $from = $m.Index + [int]($len * 50); $first = $false; $matched++; $sumScore += $m.Score
                } else { $l.Score = [Math]::Max($m.Score, 0) }
            }
            $summary = '{0}: {1} of {2} lines matched' -f $g.Source, $matched, $lines.Count
            if ($missing) { $summary += " ($missing audio clip(s) not found)" }
            $result.Considered += $summary
            $mean = if ($matched) { $sumScore / $matched } else { 0 }
            if (-not $best -or $matched -gt $best.Matched -or ($matched -eq $best.Matched -and $mean -gt $best.Mean)) {
                $best = [pscustomobject]@{ Group = $g; Lines = $lines; Matched = $matched; Mean = $mean; Missing = $missing }
            }
        }
        if ($best -and $best.Matched -gt 0) {
            $result.Group = $best.Group; $result.Lines = $best.Lines; $result.Matched = $best.Matched
            $result.Note = 'Placed by matching each recorded clip against the audio track.'
            if ($best.Matched -lt $best.Lines.Count) {
                Add-Warning ("Narration: only {0} of {1} lines from {2} were found in the audio. The rest are listed as unmatched in the report." -f $best.Matched, $best.Lines.Count, $best.Group.Source)
            }
            return $result
        }
        Add-Warning 'Narration: a script or recording table was found, but none of its clips could be matched to the audio (clip files missing, or the audio differs). Frames are listed without narration.'
    }

    $timed = @($groups | Where-Object { $_.Kind -eq 'timed' })
    if ($timed.Count) {
        $g = $timed[0]
        $ls = @($g.Lines | Sort-Object Start)
        for ($k = 0; $k -lt $ls.Count; $k++) {
            if ($null -eq $ls[$k].End) { $ls[$k].End = if ($k + 1 -lt $ls.Count) { $ls[$k + 1].Start } else { $ls[$k].Start + 5 } }
            $ls[$k].Score = 1.0
        }
        $result.Group = $g; $result.Lines = $ls; $result.Matched = $ls.Count
        $result.Note = 'Timings taken from the source file.'
        return $result
    }

    # Nothing could be placed in time.
    if ($clipGroups.Count) {
        if ($audio) { $result.Note = "Found $($clipGroups.Count) recording table(s) or voiceover file(s), but none of their clips matched the audio." }
        else {
            $result.Note = "Found $($clipGroups.Count) recording table(s) or voiceover file(s), but there is no audio to match them against."
            foreach ($g in $clipGroups) { $result.Considered += "$($g.Source): $(@($g.Lines).Count) lines" }
            Add-Warning "Narration: $($result.Note) Frames are listed without narration."
        }
    }
    $untimed = @($groups | Where-Object { $_.Kind -eq 'untimed' })
    if ($untimed.Count) {
        $result.Group = $untimed[0]; $result.Lines = @($untimed[0].Lines)
        $result.Note = ($result.Note + ' The script lines below have no timings, so they are listed but not shown under frames.').Trim()
        if (-not $clipGroups.Count) { Add-Warning "Narration: $($untimed[0].Source) has no timings or audio clips to match, so lines are not shown under frames." }
    } elseif (-not $result.Note) { $result.Note = 'No narration source found.' }
    return $result
}

function Get-NarrationAt([double]$t, $lines) {
    # The line being spoken at time t; otherwise the last line before it, marked as a pause.
    $speaking = $null; $before = $null
    foreach ($l in $lines) {
        if ($null -eq $l.Start) { continue }
        if ($t -ge $l.Start - 0.05 -and $t -le $l.End + 0.25) { $speaking = $l }
        elseif ($l.End -lt $t -and (-not $before -or $l.End -gt $before.End)) { $before = $l }
    }
    if ($speaking) { return [pscustomobject]@{ Text = $speaking.Text; Pause = $false } }
    if ($before -and $t - $before.End -lt 6) { return [pscustomobject]@{ Text = $before.Text; Pause = $true } }
    return $null
}

# ---------------------------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------------------------

function Get-SceneTimes([string]$file, [string]$work) {
    Write-Step 'Frames: finding scene changes'
    $scoreFile = 'scene-scores.txt'
    $vf = "fps=4,scale=480:-2,select='gte(scene\,0)',metadata=print:key=lavfi.scene_score:file=$scoreFile"
    [void](Invoke-Tool $script:Ffmpeg @('-hide_banner', '-nostdin', '-nostats', '-i', $file, '-an', '-vf', $vf, '-f', 'null', '-') 'scene detection' -WorkDir $work)
    $path = Join-Path $work $scoreFile
    if (-not (Test-Path -LiteralPath $path)) { throw 'Scene detection produced no scores file.' }
    # A change is a run of samples scoring at least -SceneThreshold; runs less than 0.5 s apart are
    # treated as one change (a fade out and a fade in, say).
    $runs = New-Object System.Collections.Generic.List[object]
    $t = $null; $prev = $null; $open = $null
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match 'pts_time:([\d.e+-]+)') { $prev = $t; $t = [double]$Matches[1]; continue }
        if ($line -match 'lavfi\.scene_score=([\d.e+-]+)' -and $null -ne $t) {
            if ([double]$Matches[1] -lt $SceneThreshold) { $open = $null; continue }
            if ($open) { $open.End = $t }
            elseif ($runs.Count -and $t - $runs[$runs.Count - 1].End -lt 0.5) { $open = $runs[$runs.Count - 1]; $open.End = $t }
            else { $open = [pscustomobject]@{ Before = $prev; End = $t }; $runs.Add($open) }
        }
    }
    return $runs.ToArray()
}

function Export-VideoFrames([string]$file, $media, [string]$framesDir, [string]$work) {
    $fps = if ($media.Fps -gt 0) { $media.Fps } else { 30 }
    $total = [Math]::Max(1, [int][Math]::Floor($media.Duration * $fps))
    $targets = @{}
    $add = {
        param([double]$time, [string]$why)
        $n = [int][Math]::Round($time * $fps); $n = [Math]::Min([Math]::Max($n, 0), $total - 1)
        if (-not $targets.ContainsKey($n)) { $targets[$n] = New-Object System.Collections.Generic.List[string] }
        if (-not $targets[$n].Contains($why)) { $targets[$n].Add($why) }
    }
    $grid = @()
    for ($t = 0.0; $t -lt $media.Duration - 0.001; $t += $Interval) { & $add $t 'interval'; $grid += $t }
    $scenes = @(Get-SceneTimes $file $work)
    $script:SceneRuns = $scenes
    foreach ($s in $scenes) {
        # The finished slide just before the change, and the new scene once it has settled
        # (or the regular frame just after, when one falls within 0.75 s).
        if ($null -ne $s.Before) { & $add $s.Before 'sceneend' }
        $after = [Math]::Min($s.End + 0.5, $media.Duration)
        $near = @($grid | Where-Object { $_ -ge $after - 0.25 -and $_ -le $after + 0.75 })
        if ($near.Count) { & $add $near[0] 'scene' } else { & $add $after 'scene' }
    }
    & $add ($media.Duration) 'last'
    $ns = @($targets.Keys | Sort-Object)
    Write-Step ("Frames: extracting {0} frames ({1} scene changes)" -f $ns.Count, $scenes.Count)

    $raw = Join-Path $work 'raw'
    New-Item -ItemType Directory -Force -Path $raw | Out-Null
    # ffmpeg's select expression takes at most 100 terms. When the interval is a whole number of
    # frames, all the regular frames are one term (every K-th frame); the rest are listed one by one,
    # at most 90 to a pass. Frames that come out are identified by their own timestamps.
    $framesPerInterval = $Interval * $fps
    $useMod = [Math]::Abs($framesPerInterval - [Math]::Round($framesPerInterval)) -lt 1e-6 -and [Math]::Round($framesPerInterval) -ge 1
    $K = [int][Math]::Round($framesPerInterval)
    $rest = @($ns | Where-Object { -not ($useMod -and $_ % $K -eq 0) })
    $passes = New-Object System.Collections.Generic.List[object]
    for ($b = 0; $b -lt [Math]::Max($rest.Count, 1); $b += 90) {
        $terms = @(); if ($rest.Count) { $terms = @($rest[$b..([Math]::Min($b + 90, $rest.Count) - 1)] | ForEach-Object { "eq(n\,$_)" }) }
        $passes.Add($terms)
    }
    if ($useMod) { $passes[0] = @("not(mod(n\,$K))") + $passes[0] }
    if (-not @($passes[0]).Count) { $passes.RemoveAt(0) }

    $out = New-Object System.Collections.Generic.List[object]
    $found = @{}
    for ($pi = 0; $pi -lt $passes.Count; $pi++) {
        $expr = @($passes[$pi]) -join '+'
        $prefix = 'p{0:000}_' -f $pi
        $r = Invoke-Tool $script:Ffmpeg @('-hide_banner', '-nostdin', '-nostats', '-i', $file, '-an', '-vf', "select='$expr',showinfo",
            '-fps_mode', 'vfr', (Join-Path $raw "$prefix%05d.png")) "frame extraction (pass $($pi + 1) of $($passes.Count))"
        $times = @([regex]::Matches($r.Err, 'n:\s*\d+\s+pts:\s*-?\d+\s+pts_time:([\d.e+-]+)') | ForEach-Object { [double]$_.Groups[1].Value })
        $files = @(Get-ChildItem -LiteralPath $raw -Filter "$prefix*.png" | Sort-Object Name)
        if ($files.Count -ne $times.Count) { throw "Frame extraction wrote $($files.Count) frames but reported $($times.Count) timestamps." }
        for ($j = 0; $j -lt $files.Count; $j++) {
            $n = [int][Math]::Round($times[$j] * $fps)
            if ($found.ContainsKey($n)) { Remove-Item -LiteralPath $files[$j].FullName; continue }
            $why = if ($targets.ContainsKey($n)) { @($targets[$n]) } else { @('interval') }
            $found[$n] = $true
            $out.Add([pscustomobject]@{ Raw = $files[$j].FullName; Time = $times[$j]; Frame = $n; Reasons = $why })
        }
    }
    $missing = @($ns | Where-Object { -not $found.ContainsKey($_) })
    if ($missing.Count) {
        Add-Warning ("{0} requested frame(s) could not be extracted (frame numbers {1}). The video may have a variable frame rate." -f $missing.Count, (($missing | Select-Object -First 10) -join ', '))
    }
    if (-not $out.Count) { throw 'No frames were extracted.' }
    return Save-Frames $out $framesDir
}

function Save-Frames($list, [string]$framesDir) {
    $i = 0
    $result = @()
    foreach ($f in ($list | Sort-Object Time)) {
        $i++
        $tag = if ($f.Reasons -contains 'scene') { 'scene' } elseif ($f.Reasons -contains 'sceneend') { 'end' } elseif ($f.Reasons -contains 'chosen') { "frame$($f.Frame)" } elseif ($f.Reasons -contains 'interval') { 'interval' } else { $f.Reasons[0] }
        $name = '{0:0000}_{1}_{2}.png' -f $i, (Format-Stamp $f.Time), $tag
        $dest = Join-Path $framesDir $name
        Move-Item -LiteralPath $f.Raw -Destination $dest -Force
        $why = @($f.Reasons | ForEach-Object {
                switch ($_) { 'interval' { "every $Interval s" } 'scene' { 'scene change' } 'sceneend' { 'end of scene' } 'last' { 'last frame' } 'chosen' { 'chosen frame' } default { $_ } }
            }) -join ', '
        $result += [pscustomobject]@{ Index = $i; Time = $f.Time; Frame = $f.Frame; Name = $name; Path = $dest; Why = $why; Narr = $null
            Lines = @(); Text = ''; Misspelt = @(); Flags = (New-Object System.Collections.Generic.List[string]); Sig = $null; Change = $null; TokA = @(); TokB = @() }
    }
    return $result
}

# ---------------------------------------------------------------------------------------------
# Remotion
# ---------------------------------------------------------------------------------------------

function Invoke-Npx([string[]]$ArgList, [string]$What, [string]$project) {
    return Invoke-Tool $script:Npx $ArgList $What -WorkDir $project
}

function Initialize-Remotion([string]$project, [string]$work) {
    $pkg = Join-Path $project 'package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { throw "$project has no package.json, so it is not a Remotion project. Pass a video file or a Remotion project folder." }
    if ([IO.File]::ReadAllText($pkg) -notmatch '"remotion"\s*:') { throw "$pkg does not list remotion as a dependency." }
    if (-not (Test-Path -LiteralPath (Join-Path $project 'node_modules\@remotion\cli'))) {
        throw "Remotion's CLI is not installed in $project. Run 'npm install' in that folder first."
    }
    $script:Npx = Get-ToolPath 'npx.cmd'; if (-not $script:Npx) { $script:Npx = Get-ToolPath 'npx' }
    if (-not $script:Npx) { throw 'npx not found. Install Node.js (winget install OpenJS.NodeJS.LTS) and open a new PowerShell window.' }

    Write-Step 'Remotion: bundling the project once (reused for every still)'
    $bundle = Join-Path $work 'bundle'
    [void](Invoke-Npx @('remotion', 'bundle', '--out-dir', $bundle, '--log=error') 'npx remotion bundle' $project)
    $list = Invoke-Npx @('remotion', 'compositions', $bundle) 'npx remotion compositions' $project
    $esc = [char]27
    $comps = @()
    foreach ($line in ($list.Out -split "`r?`n")) {
        $l = ($line -replace "$esc\[[0-9;]*m", '').Trim()
        if ($l -match '^(\S+)\s+([\d.]+)\s+(\d+)x(\d+)\s+(\d+)\s+\(([\d.]+) sec\)') {
            $comps += [pscustomobject]@{ Id = $Matches[1]; Fps = [double]$Matches[2]; Width = [int]$Matches[3]; Height = [int]$Matches[4]; Frames = [int]$Matches[5] }
        }
    }
    if (-not $comps.Count) { throw "Could not read any compositions from 'npx remotion compositions'. Output was:`n$($list.Out)" }
    $comp = if ($Composition) { $comps | Where-Object { $_.Id -eq $Composition } | Select-Object -First 1 } else { $comps[0] }
    if (-not $comp) { throw "Composition '$Composition' not found. Available: $(($comps | ForEach-Object { $_.Id }) -join ', ')" }
    if (-not $Composition -and $comps.Count -gt 1) { Write-Host "    Using the first composition, $($comp.Id). Others: $((@($comps | Select-Object -Skip 1) | ForEach-Object { $_.Id }) -join ', ')" }
    return [pscustomobject]@{ Bundle = $bundle; Comp = $comp; All = $comps }
}

function Export-RemotionFrames([string]$project, $rem, [string]$framesDir, [string]$work) {
    $c = $rem.Comp
    $targets = @{}
    if ($Frames) {
        # Accepts 0,90,450 as an array or as one string (powershell -File passes it as text).
        $list = @($Frames | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object {
                if ($_ -notmatch '^\d+$') { throw "-Frames takes whole frame numbers, e.g. 0,90,450 (got '$_')." }; [int]$_ })
        foreach ($f in $list) {
            if ($f -lt 0 -or $f -ge $c.Frames) { throw "Frame $f is outside composition $($c.Id) (frames 0 to $($c.Frames - 1))." }
            $targets[$f] = @('chosen')
        }
    } else {
        for ($t = 0.0; $t * $c.Fps -lt $c.Frames - 0.5; $t += $Interval) { $targets[[int][Math]::Round($t * $c.Fps)] = @('interval') }
        $lastF = $c.Frames - 1
        if ($targets.ContainsKey($lastF)) { $targets[$lastF] += 'last' } else { $targets[$lastF] = @('last') }
    }
    $ns = @($targets.Keys | Sort-Object)
    $raw = Join-Path $work 'raw'
    New-Item -ItemType Directory -Force -Path $raw | Out-Null
    $list = New-Object System.Collections.Generic.List[object]
    $k = 0
    foreach ($n in $ns) {
        $k++
        Write-Host ("    still {0}/{1}: frame {2} ({3})" -f $k, $ns.Count, $n, (Format-Time ($n / $c.Fps)))
        $png = Join-Path $raw ('r{0:000000}.png' -f $n)
        [void](Invoke-Npx @('remotion', 'still', $rem.Bundle, $c.Id, $png, "--frame=$n", '--image-format=png', '--overwrite', '--log=error') "npx remotion still (frame $n)" $project)
        if (-not (Test-Path -LiteralPath $png)) { throw "npx remotion still did not write $png" }
        $list.Add([pscustomobject]@{ Raw = $png; Time = $n / $c.Fps; Frame = $n; Reasons = @($targets[$n]) })
    }
    return Save-Frames $list $framesDir
}

# ---------------------------------------------------------------------------------------------
# PDF
# ---------------------------------------------------------------------------------------------

function New-Thumbs($frames, [string]$dir, [int]$longSide, [int]$quality, [bool]$portrait) {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $listFile = Join-Path $dir 'list.txt'
    Write-ConcatList $frames $listFile
    $scale = if ($portrait) { "scale=-2:'min($longSide,ih)'" } else { "scale='min($longSide,iw)':-2" }
    [void](Invoke-Tool $script:Ffmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', $listFile,
            '-vf', $scale, '-fps_mode', 'passthrough', '-q:v', "$quality", (Join-Path $dir 't%05d.jpg')) 'thumbnail creation')
    $thumbs = @(Get-ChildItem -LiteralPath $dir -Filter 't*.jpg' | Sort-Object Name)
    if ($thumbs.Count -ne @($frames).Count) { throw "Thumbnail creation made $($thumbs.Count) images for $(@($frames).Count) frames." }
    return @($thumbs | ForEach-Object { $_.Name })
}

function Write-PdfHtml([string]$htmlPath, $ctx, $frames, [string[]]$thumbNames, [string]$thumbRel) {
    $w = [Math]::Max(1, $ctx.Width); $h = [Math]::Max(1, $ctx.Height)
    $ar = $w / $h
    $hasNarr = @($frames | Where-Object { $_.Narr -or $_.Text }).Count -gt 0
    # Page layout: about 6 to 9 frames a page, leaving room for the narration and on-screen text.
    if ($ar -ge 1.2) { $orient = 'landscape'; $pw = 281; $ph = 194; $cols = 3; $rows = if ($hasNarr) { 2 } else { 3 } }
    elseif ($ar -le 0.83) { $orient = 'portrait'; $pw = 194; $ph = 281; $cols = 4; $rows = 2 }
    else { $orient = 'portrait'; $pw = 194; $ph = 281; $cols = 3; $rows = if ($hasNarr) { 2 } else { 3 } }
    $gap = 3; $headH = 7
    $cellW = ($pw - ($cols - 1) * $gap) / $cols
    $cellH = ($ph - $headH - ($rows - 1) * $gap) / $rows
    $reserve = if ($hasNarr) { 18 } else { 7 }
    $imgH = [Math]::Min($cellW / $ar, $cellH - $reserve - 2)
    $perPage = $cols * $rows

    $css = @"
@page { size: A4 $orient; margin: 8mm; }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Arial, sans-serif; color: #111; margin: 0; font-size: 9pt; }
h1 { font-size: 16pt; margin: 0 0 2mm; } h2 { font-size: 11.5pt; margin: 5mm 0 1.5mm; border-bottom: 0.3mm solid #999; }
table { border-collapse: collapse; margin: 1mm 0 2mm; } td, th { border: 0.2mm solid #bbb; padding: 0.7mm 2mm; text-align: left; vertical-align: top; font-size: 8.5pt; }
th { background: #eee; } .muted { color: #666; } .warn { color: #a40000; font-weight: 600; }
.cover { page-break-after: always; }
.page { height: ${ph}mm; page-break-after: always; overflow: hidden; display: flex; flex-direction: column; }
.page:last-child { page-break-after: auto; }
.head { height: ${headH}mm; font-size: 8pt; color: #555; display: flex; justify-content: space-between; align-items: flex-start; }
.grid { display: grid; grid-template-columns: repeat($cols, ${cellW}mm); grid-auto-rows: ${cellH}mm; gap: ${gap}mm; }
.cell { border: 0.2mm solid #ccc; padding: 1mm; overflow: hidden; display: flex; flex-direction: column; }
.cell img { width: 100%; height: ${imgH}mm; object-fit: contain; background: #000; display: block; }
.ts { font-weight: 700; font-size: 9.5pt; margin-top: 0.8mm; } .why { font-weight: 400; color: #666; font-size: 7.5pt; }
.nar { font-size: 7.6pt; line-height: 1.25; margin-top: 0.5mm; overflow: hidden; }
.pause { color: #777; font-style: italic; }
.ocr { font-size: 7pt; line-height: 1.2; color: #24476b; margin-top: 0.6mm; overflow: hidden; max-height: 22mm; }
.flag { font-size: 7pt; line-height: 1.2; color: #a40000; font-weight: 600; margin-top: 0.4mm; }
.bad { color: #c00000; font-weight: 700; text-decoration: underline; }
"@
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>$(Get-Html $ctx.Title)</title><style>$css</style></head><body>")
    [void]$sb.Append("<div class='cover'>")
    [void]$sb.Append($ctx.CoverHtml)
    [void]$sb.Append("<h2>Contact sheet</h2><p>$(@($frames).Count) frames follow, $perPage to a page, in time order. Each is labelled with its timestamp and why it was taken")
    [void]$sb.Append('. Under it: any problems found (red), the narration at that moment (grey italic: a pause, showing the line just spoken) and the text on screen as read by OCR (blue; possible misspellings underlined).</p></div>')

    $fa = @($frames)
    $pages = [Math]::Ceiling($fa.Count / $perPage)
    for ($p = 0; $p -lt $pages; $p++) {
        $chunk = @($fa[($p * $perPage)..([Math]::Min(($p + 1) * $perPage, $fa.Count) - 1)])
        [void]$sb.Append("<div class='page'><div class='head'><span>$(Get-Html $ctx.Title)</span><span>Frames #$($chunk[0].Index) to #$($chunk[-1].Index) &middot; page $($p + 1) of $pages</span></div><div class='grid'>")
        for ($q = 0; $q -lt $chunk.Count; $q++) {
            $f = $chunk[$q]
            $thumb = "$thumbRel/" + $thumbNames[$p * $perPage + $q]
            [void]$sb.Append("<div class='cell'><img src='$thumb'><div class='ts'>#$($f.Index) &nbsp;$(Format-Time $f.Time) <span class='why'>$(Get-Html $f.Why)</span></div>")
            foreach ($fl in @($f.Flags | Where-Object { $_ -notmatch '^spelling' } | Select-Object -Unique)) { [void]$sb.Append("<div class='flag'>$(Get-Html $fl)</div>") }
            if ($f.Narr) {
                $cls = if ($f.Narr.Pause) { 'nar pause' } else { 'nar' }
                $txt = $f.Narr.Text
                if ($f.Narr.Pause) { $txt = "(pause) $txt" }
                [void]$sb.Append("<div class='$cls'>$(Get-Html $txt)</div>")
            }
            if ($f.Text) {
                $h = Get-Html $f.Text
                foreach ($bw in @($f.Misspelt)) { $h = [regex]::Replace($h, '\b' + [regex]::Escape((Get-Html $bw)) + '\b', "<span class='bad'>$(Get-Html $bw)</span>") }
                [void]$sb.Append("<div class='ocr'>Screen: $h</div>")
            }
            [void]$sb.Append('</div>')
        }
        [void]$sb.Append('</div></div>')
    }
    [void]$sb.Append('</body></html>')
    Write-Utf8 $htmlPath $sb.ToString()
}

function New-ReviewPdf($ctx, $frames, [string]$outDir, [string]$work, [string]$suffix = 'review') {
    $browser = Find-Browser
    if (-not $browser) { throw 'Microsoft Edge or Google Chrome is needed to make the PDF and neither was found. Install one, or run with -NoPdf.' }
    $pdf = Join-Path $outDir ($ctx.BaseName + "-$suffix.pdf")
    $html = Join-Path $work 'contact-sheet.html'
    $portrait = $ctx.Height -gt $ctx.Width
    $limit = $MaxPdfMB * 1MB
    $steps = @(@(960, 3), @(800, 4), @(640, 5), @(512, 6), @(400, 7), @(320, 8), @(240, 10))
    $size = 0
    foreach ($s in $steps) {
        Write-Step ("PDF ({0}): contact sheet with frames at {1} px (long side)" -f $suffix, $s[0])
        # A fresh folder, page and browser profile for each attempt, in case a browser process from
        # the previous attempt is still closing.
        $tag = "$suffix-$($s[0])"
        $names = New-Thumbs $frames (Join-Path $work "thumbs-$tag") $s[0] $s[1] $portrait
        $html = Join-Path $work "contact-sheet-$tag.html"
        Write-PdfHtml $html $ctx $frames $names "thumbs-$tag"
        if (Test-Path -LiteralPath $pdf) { Remove-Item -LiteralPath $pdf -Force }
        $url = ([Uri]$html).AbsoluteUri
        $r = Invoke-Tool $browser @('--headless', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
            '--no-pdf-header-footer', '--print-to-pdf-no-header', "--user-data-dir=$(Join-Path $work "browser-profile-$tag")",
            "--print-to-pdf=$pdf", $url) 'PDF printing' -AllowFail -NoCapture
        # The browser's launcher can exit before the PDF is finished: wait until the file exists,
        # has stopped growing and can be opened exclusively.
        $deadline = (Get-Date).AddSeconds(180); $lastLen = -1; $ready = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $pdf) {
                $len = (Get-Item -LiteralPath $pdf).Length
                if ($len -gt 0 -and $len -eq $lastLen) {
                    try { $fs = [IO.File]::Open($pdf, 'Open', 'Read', 'None'); $fs.Close(); $ready = $true; break } catch { }
                }
                $lastLen = $len
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw "The browser did not finish writing the PDF within 3 minutes ($browser, exit code $($r.Code))." }
        $size = (Get-Item -LiteralPath $pdf).Length
        if ($size -le $limit) { break }
        Write-Host ("    {0:0.0} MB is over the {1} MB limit; trying smaller frames" -f ($size / 1MB), $MaxPdfMB)
    }
    if ($size -gt $limit) {
        Add-Warning ("The PDF is {0:0.0} MB, over the {1} MB limit even with the smallest frames. Use a larger -Interval or a higher -SceneThreshold for fewer frames." -f ($size / 1MB), $MaxPdfMB)
    }
    return [pscustomobject]@{ Path = $pdf; SizeMB = $size / 1MB; LongSide = $s[0] }
}

# ---------------------------------------------------------------------------------------------
# Report text
# ---------------------------------------------------------------------------------------------

function Get-AudioNotes($audio) {
    if ([double]::IsNegativeInfinity([double]$audio.TruePeak) -or $audio.Integrated -le -69.9) {
        return @('The audio track is silent: nothing measurable (integrated loudness at the -70 LUFS floor).')
    }
    $notes = @()
    if ($null -ne $audio.TruePeak -and $audio.TruePeak -gt -1.0) { $notes += ('True peak is {0}, above -1 dBTP: lossy encoding (YouTube, social apps) may clip it.' -f (Format-Db $audio.TruePeak 'dBTP')) }
    if ($audio.Integrated -gt -9) { $notes += 'Integrated loudness is very high (above -9 LUFS).' }
    elseif ($audio.Integrated -lt -24 -and -not [double]::IsNegativeInfinity($audio.Integrated)) { $notes += 'Integrated loudness is low (below -24 LUFS); it may sound quiet next to other videos.' }
    if ($audio.Scan.ClippedSamples -gt 0) { $notes += ('{0} samples at or above {1}: likely clipping (times below).' -f $audio.Scan.ClippedSamples, (Format-Db $ClipDb)) }
    if ($audio.Clicks.Count) { $notes += ('{0} possible click(s) or pop(s): listen at the times below.' -f $audio.Clicks.Count) }
    if (-not $notes.Count) { $notes += 'No clipping, clicks or pops, and the true peak is below -1 dBTP.' }
    $notes += 'For reference, YouTube plays videos back at about -14 LUFS; podcasts usually aim for -16 LUFS.'
    return $notes
}

function Get-SilenceNote($s, [double]$duration) {
    if ($s.Start -le 0.05) { return 'at the start' }
    if ($s.End -ge $duration - 0.05) { return 'at the end' }
    return ''
}

function Build-Cover($ctx, $audio, $narr, $frames, $checks, $chg) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<h1>Video review: $(Get-Html $ctx.Title)</h1><p class='muted'>$(Get-Html $ctx.SourceLine) &middot; made $(Get-Date -Format 'yyyy-MM-dd HH:mm') with review-video.ps1</p>")
    if ($script:Warnings.Count) {
        [void]$sb.Append('<h2>Warnings</h2><ul>'); foreach ($w in $script:Warnings) { [void]$sb.Append("<li class='warn'>$(Get-Html $w)</li>") }; [void]$sb.Append('</ul>')
    }
    [void]$sb.Append((Build-ChangesHtml $chg))
    [void]$sb.Append('<h2>Summary</h2><table>')
    foreach ($row in $ctx.Summary) { [void]$sb.Append("<tr><th>$(Get-Html $row[0])</th><td>$(Get-Html $row[1])</td></tr>") }
    [void]$sb.Append('</table>')
    [void]$sb.Append((Build-ChecksHtml $checks))
    if ($audio) {
        [void]$sb.Append('<h2>Audio findings</h2><ul>'); foreach ($n in (Get-AudioNotes $audio)) { [void]$sb.Append("<li>$(Get-Html $n)</li>") }; [void]$sb.Append('</ul>')
        if ($audio.Loudest.Count) {
            [void]$sb.Append('<table><tr><th>Loudest moments</th><th>Peak</th></tr>')
            foreach ($l in $audio.Loudest) { [void]$sb.Append("<tr><td>$(Format-Time $l.Time)</td><td>$(Format-Db $l.Peak)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append("<p><b>Silences longer than $MinSilence s</b> (below $SilenceDb dBFS): ")
        if ($audio.Silences.Count) {
            [void]$sb.Append('</p><table><tr><th>Start</th><th>End</th><th>Length</th><th></th></tr>')
            foreach ($s in $audio.Silences) { [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2:0.00} s</td><td>{3}</td></tr>' -f (Format-Time $s.Start), (Format-Time $s.End), $s.Length, (Get-SilenceNote $s $ctx.Duration))) }
            [void]$sb.Append('</table>')
        } else { [void]$sb.Append('none.</p>') }
        [void]$sb.Append('<p><b>Possible clicks or pops</b>: ')
        if ($audio.Clicks.Count) {
            [void]$sb.Append('</p><table><tr><th>Time</th><th>Jump</th><th>vs surroundings</th></tr>')
            foreach ($c in ($audio.Clicks | Select-Object -First 25)) { [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2:0}x</td></tr>' -f (Format-Time $c.Time), (Format-Db $c.Level), $c.Ratio)) }
            [void]$sb.Append('</table>')
            if ($audio.Clicks.Count -gt 25) { [void]$sb.Append("<p class='muted'>$($audio.Clicks.Count - 25) more in report.md.</p>") }
        } else { [void]$sb.Append('none found.</p>') }
        if ($audio.Clipping.Count) {
            [void]$sb.Append('<p><b>Clipping</b> at: ' + (($audio.Clipping | Select-Object -First 20 | ForEach-Object { Format-Time $_.Time }) -join ', ') + '</p>')
        }
    }
    if (-not $narr.Group) { [void]$sb.Append("<h2>Narration</h2><p>$(Get-Html $narr.Note)</p>") }
    if ($narr.Group) {
        [void]$sb.Append("<h2>Narration</h2><p>Source: $(Get-Html $narr.Group.Source). $(Get-Html $narr.Note)</p>")
        $un = @($narr.Lines | Where-Object { $null -eq $_.Start })
        if ($narr.Matched -and $un.Count) {
            [void]$sb.Append("<p class='warn'>Not found in the audio ($($un.Count)):</p><ul>")
            foreach ($u in ($un | Select-Object -First 15)) { [void]$sb.Append("<li>$(Get-Html $u.Text)</li>") }
            [void]$sb.Append('</ul>')
        }
    }
    return $sb.ToString()
}

function Build-Report($ctx, $audio, $narr, $frames, $pdfInfo, $checks, $chg, $changesPdf) {
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    [void]$sb.Append("# Video review: $($ctx.Title)$nl$nl")
    [void]$sb.Append("$($ctx.SourceLine). Made $(Get-Date -Format 'yyyy-MM-dd HH:mm') by review-video.ps1 (ffmpeg $($script:FfmpegVersion)).$nl$nl")
    [void]$sb.Append("**How to use this report.** Every frame listed below is a PNG in ``frames/``, named ``<number>_<hh-mm-ss.mmm>_<reason>.png``. ")
    [void]$sb.Append("Open the frames alongside this report and check what is on screen against the narration given for that moment ")
    [void]$sb.Append("(the line being spoken, or the line just spoken during a pause) and against the on-screen text read by OCR. The changes since the last review (if any) come first, then audio, narration, the on-screen text checks and the frames.$nl$nl")
    if ($script:Warnings.Count) {
        [void]$sb.Append("## Warnings$nl$nl"); foreach ($w in $script:Warnings) { [void]$sb.Append("- **$w**$nl") }; [void]$sb.Append($nl)
    }
    if ($chg) { [void]$sb.Append((Build-ChangesMarkdown $chg $nl)) }
    [void]$sb.Append("## Summary$nl$nl| | |$nl|---|---|$nl")
    foreach ($row in $ctx.Summary) { [void]$sb.Append("| $($row[0]) | $(Get-Md $row[1]) |$nl") }
    if ($pdfInfo) { [void]$sb.Append(('| PDF | {0} ({1:0.0} MB, frames at {2} px) |{3}' -f [IO.Path]::GetFileName($pdfInfo.Path), $pdfInfo.SizeMB, $pdfInfo.LongSide, $nl)) }
    if ($changesPdf) { [void]$sb.Append(('| Changes PDF | {0} ({1:0.0} MB, changed frames only) |{2}' -f [IO.Path]::GetFileName($changesPdf.Path), $changesPdf.SizeMB, $nl)) }
    [void]$sb.Append($nl)

    [void]$sb.Append("## Audio$nl$nl")
    if (-not $audio) { [void]$sb.Append("$($ctx.NoAudioReason)$nl$nl") }
    else {
        [void]$sb.Append("### Loudness and peaks$nl$nl")
        [void]$sb.Append(('- Length: {0} ({1:0.000} s){2}' -f (Format-Time $audio.Length), $audio.Length, $nl))
        [void]$sb.Append(('- Integrated loudness: {0}; loudness range (LRA): {1:0.0} LU{2}' -f (Format-Db $audio.Integrated 'LUFS'), $audio.Lra, $nl))
        [void]$sb.Append(('- True peak: {0}; sample peak: {1} at {2}{3}' -f (Format-Db $audio.TruePeak 'dBTP'), (Format-Db $audio.Scan.SamplePeakDb), (Format-Time $audio.Scan.SamplePeakTime), $nl))
        foreach ($n in (Get-AudioNotes $audio)) { [void]$sb.Append("- $n$nl") }
        if ($audio.Loudest.Count) {
            [void]$sb.Append("$nl| Loudest moments (100 ms windows) | Peak |$nl|---|---|$nl")
            foreach ($l in $audio.Loudest) { [void]$sb.Append("| $(Format-Time $l.Time) | $(Format-Db $l.Peak) |$nl") }
        }
        [void]$sb.Append("$nl### Clipping$nl$nl")
        if ($audio.Clipping.Count) {
            [void]$sb.Append(('{0} samples at or above {1}, in {2} place(s):{3}{3}| Time | Level |{3}|---|---|{3}' -f $audio.Scan.ClippedSamples, (Format-Db $ClipDb), $audio.Clipping.Count, $nl))
            foreach ($c in ($audio.Clipping | Select-Object -First 100)) { [void]$sb.Append("| $(Format-Time $c.Time) | $(Format-Db $c.Level) |$nl") }
        } else { [void]$sb.Append("None (no samples at or above $(Format-Db $ClipDb)).$nl") }
        [void]$sb.Append("$nl### Silences longer than $MinSilence s$nl$nl")
        if ($audio.Silences.Count) {
            [void]$sb.Append("Audio below $SilenceDb dBFS.$nl$nl| Start | End | Length | Note |$nl|---|---|---|---|$nl")
            foreach ($s in $audio.Silences) { [void]$sb.Append(('| {0} | {1} | {2:0.00} s | {3} |{4}' -f (Format-Time $s.Start), (Format-Time $s.End), $s.Length, (Get-SilenceNote $s $ctx.Duration), $nl)) }
        } else { [void]$sb.Append("None (threshold $SilenceDb dBFS).$nl") }
        [void]$sb.Append("$nl### Possible clicks or pops$nl$nl")
        [void]$sb.Append("A jump in the waveform at least ${ClickRatio}x larger than the signal in the 2 ms around it and above $ClickMinDb dBFS: a click, a pop, or audio that starts or stops without a fade.$nl$nl")
        if ($audio.Clicks.Count) {
            [void]$sb.Append("| Time | Jump | vs surroundings | Channel |$nl|---|---|---|---|$nl")
            foreach ($c in ($audio.Clicks | Select-Object -First 100)) {
                $chName = if ($ctx.Channels -eq 1) { 'mono' } elseif ($c.Channel -eq 0) { 'left' } else { 'right' }
                [void]$sb.Append(('| {0} | {1} | {2:0}x | {3} |{4}' -f (Format-Time $c.Time), (Format-Db $c.Level), $c.Ratio, $chName, $nl))
            }
            if ($audio.Clicks.Count -gt 100) { [void]$sb.Append("$nl$($audio.Clicks.Count - 100) more not listed (the strongest 100 are shown).$nl") }
        } else { [void]$sb.Append("None found.$nl") }
        [void]$sb.Append($nl)
    }

    [void]$sb.Append("## Narration$nl$nl")
    if (-not $narr.Group) {
        [void]$sb.Append("$($narr.Note) Frames are listed without narration. See the README for the formats it looks for.$nl$nl")
        if ($narr.Considered.Count) { [void]$sb.Append("Candidates checked:$nl$nl"); foreach ($c in $narr.Considered) { [void]$sb.Append("- $c$nl") }; [void]$sb.Append($nl) }
    }
    else {
        [void]$sb.Append("Source: ``$($narr.Group.Source)``. $($narr.Note)$nl$nl")
        if ($narr.Considered.Count -gt 1) { [void]$sb.Append("Candidates checked:$nl$nl"); foreach ($c in $narr.Considered) { [void]$sb.Append("- $c$nl") }; [void]$sb.Append($nl) }
        [void]$sb.Append("| # | Start | End | Match | Line |$nl|---|---|---|---|---|$nl")
        $k = 0
        foreach ($l in $narr.Lines) {
            $k++
            if ($null -ne $l.Start) { [void]$sb.Append(('| {0} | {1} | {2} | {3:0.00} | {4} |{5}' -f $k, (Format-Time $l.Start), (Format-Time $l.End), $l.Score, (Get-Md $l.Text), $nl)) }
            else { [void]$sb.Append(('| {0} | | | {1} | {2} |{3}' -f $k, $(if ($narr.Matched) { 'not found' } else { '' }), (Get-Md $l.Text), $nl)) }
        }
        [void]$sb.Append($nl)
    }

    [void]$sb.Append((Build-ChecksMarkdown $checks $nl))

    [void]$sb.Append("## Frames$nl$nl")
    [void]$sb.Append("$(@($frames).Count) frames. ")
    if ($ctx.Mode -eq 'video') {
        [void]$sb.Append("Taken every $Interval s and at the last frame. Around each scene change (a scene score of at least $SceneThreshold between samples 0.25 s apart) there are two: ")
        [void]$sb.Append("'end of scene', the finished slide just before the change, and 'scene change', the new scene 0.5 s after it settles (merged into a regular frame when one falls within 0.75 s).$nl$nl")
    }
    else { [void]$sb.Append("Rendered with ``npx remotion still`` from composition ``$($ctx.CompId)`` at $($ctx.Fps) fps.$nl$nl") }
    [void]$sb.Append("On-screen text is in reading order with lines separated by `` / ``; possible misspellings are in **bold**.$nl$nl")
    [void]$sb.Append("| # | Time | Frame no. | Why | File | Narration at this moment | On screen (OCR) | Flags |$nl|---|---|---|---|---|---|---|---|$nl")
    foreach ($f in $frames) {
        $n = ''
        if ($f.Narr) { $n = if ($f.Narr.Pause) { "_(pause; last line)_ $($f.Narr.Text)" } else { $f.Narr.Text } }
        $o = Get-Md $f.Text
        foreach ($bw in @($f.Misspelt)) { $o = [regex]::Replace($o, '\b' + [regex]::Escape($bw) + '\b', "**$bw**") }
        $fl = (@($f.Flags | Select-Object -Unique) -join '; ')
        if ($f.Change) { $fl = ('changed since last review' + $(if ($fl) { "; $fl" } else { '' })) }
        [void]$sb.Append("| $($f.Index) | $(Format-Time $f.Time) | $($f.Frame) | $($f.Why) | [$($f.Name)](frames/$($f.Name)) | $(Get-Md $n) | $o | $(Get-Md $fl) |$nl")
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

. (Join-Path $PSScriptRoot 'review-checks.ps1')

$exitCode = 0
$work = $null
try {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Not found: $Path" }
    $item = Get-Item -LiteralPath $Path
    $mode = if ($item.PSIsContainer) { 'remotion' } else { 'video' }
    if ($Interval -le 0) { throw '-Interval must be more than 0.' }
    Assert-Ffmpeg

    if ($mode -eq 'video') {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($item.Name)
        if (-not $OutDir) { $OutDir = Join-Path $item.DirectoryName "$baseName-review" }
        if (-not $Project) { $Project = Find-ProjectFolder $item.DirectoryName }
    } else {
        $Project = $item.FullName
    }
    if ($Project) { $Project = (Resolve-Path -LiteralPath $Project).Path }

    # Remotion setup needs a work folder before the output folder name is known.
    $tmpWork = Join-Path ([IO.Path]::GetTempPath()) ('video-review-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmpWork | Out-Null
    $work = $tmpWork

    $rem = $null
    if ($mode -eq 'remotion') {
        $rem = Initialize-Remotion $item.FullName $work
        $baseName = $rem.Comp.Id
        if (-not $OutDir) { $OutDir = Join-Path $item.FullName "out\$baseName-review" }
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
    # Keep the last run for the "changes since the last review" comparison.
    $prevDir = $null
    if ($CompareWith) {
        if (-not (Test-Path -LiteralPath $CompareWith)) { throw "-CompareWith folder not found: $CompareWith" }
        $prevDir = (Resolve-Path -LiteralPath $CompareWith).Path.TrimEnd('\')
        if ($prevDir -ieq $OutDir) { $prevDir = Move-PreviousReview $OutDir }
    } elseif (Test-Path -LiteralPath (Join-Path $OutDir 'review.json')) {
        $prevDir = Move-PreviousReview $OutDir
    } elseif (Test-Path -LiteralPath (Join-Path $OutDir 'previous\review.json')) {
        # The last run stopped before finishing; compare with the review kept before it.
        $prevDir = Join-Path $OutDir 'previous'
    }
    $previous = if ($prevDir) { Read-PreviousReview $prevDir } else { $null }
    $framesDir = Join-Path $OutDir 'frames'
    New-Item -ItemType Directory -Force -Path $framesDir | Out-Null
    # Clear frames from an earlier run (only files this script names), so the folder matches the report.
    Get-ChildItem -LiteralPath $framesDir -Filter '*.png' | Where-Object { $_.Name -match '^\d{4}_\d\d-\d\d-\d\d\.\d{3}_[a-z0-9]+\.png$' } | Remove-Item -Force
    Write-Host "Output: $OutDir"

    $audio = $null; $noAudioReason = ''
    if ($mode -eq 'video') {
        $media = Get-MediaInfo $item.FullName
        if (-not $media.HasVideo) { throw "$($item.Name) has no video stream." }
        if ($media.Duration -le 0) { throw "Could not read the length of $($item.Name)." }
        $frameList = @(Export-VideoFrames $item.FullName $media $framesDir $work)
        $audioFile = $item.FullName
        if ($media.HasAudio) { $audio = Invoke-AudioChecks $audioFile $media } else { $noAudioReason = 'The video has no audio track.'; Add-Warning 'The video has no audio track.' }
        $ctx = [ordered]@{ Mode = 'video'; Title = $item.Name; BaseName = $baseName; Width = $media.Width; Height = $media.Height
            Fps = $media.Fps; Duration = $media.Duration; Channels = $media.Channels
            SourceLine = "Source: $($item.Name) (video file)" }
        $videoLine = '{0}x{1}, {2:0.###} fps, {3}' -f $media.Width, $media.Height, $media.Fps, $media.VideoCodec
        $audioLine = if ($media.HasAudio) { '{0}, {1} Hz, {2} channel(s)' -f $media.AudioCodec, $media.SampleRate, $media.Channels } else { 'none' }
    } else {
        $c = $rem.Comp
        $duration = $c.Frames / $c.Fps
        Write-Step "Remotion: rendering stills of $($c.Id) with npx remotion still"
        $frameList = @(Export-RemotionFrames $item.FullName $rem $framesDir $work)
        $media = $null
        if ($NoAudio) { $noAudioReason = 'Audio was skipped (-NoAudio).' }
        else {
            Write-Step 'Remotion: rendering the audio track only (no video frames)'
            $audioFile = Join-Path $work 'audio.wav'
            $ar = Invoke-Npx @('remotion', 'render', $rem.Bundle, $c.Id, $audioFile, '--codec=wav', '--log=error') 'npx remotion render (audio only)' $item.FullName
            if (-not (Test-Path -LiteralPath $audioFile)) { throw 'The audio render did not produce a file.' }
            $media = Get-MediaInfo $audioFile
            if ($media.HasAudio) { $audio = Invoke-AudioChecks $audioFile $media } else { $noAudioReason = 'The composition rendered without audio.' }
        }
        $ctx = [ordered]@{ Mode = 'remotion'; Title = "$($c.Id) ($($item.Name))"; BaseName = $baseName; Width = $c.Width; Height = $c.Height
            Fps = $c.Fps; Duration = $duration; Channels = $(if ($media) { $media.Channels } else { 0 }); CompId = $c.Id
            SourceLine = "Source: Remotion composition $($c.Id) in project folder $($item.Name) (stills rendered, no full render)" }
        $videoLine = '{0}x{1}, {2:0.###} fps, {3} frames' -f $c.Width, $c.Height, $c.Fps, $c.Frames
        $audioLine = if ($audio) { '{0} Hz, {1} channel(s) (rendered audio track)' -f $media.SampleRate, $media.Channels } else { $noAudioReason }
    }
    $ctx.NoAudioReason = $noAudioReason

    # Narration
    $narr = [pscustomobject]@{ Group = $null; Lines = @(); Matched = 0; Considered = @(); Note = 'No narration source found.' }
    $groups = @(Find-NarrationGroups $(if ($mode -eq 'video') { $item.FullName } else { $null }) $Project)
    if ($groups.Count) {
        if ($audio -or @($groups | Where-Object { $_.Kind -eq 'timed' }).Count) { Initialize-AudioScan }
        $narr = Invoke-NarrationMatch $groups $Project $audio
    }
    foreach ($f in $frameList) { if ($narr.Matched) { $f.Narr = Get-NarrationAt $f.Time $narr.Lines } }

    # On-screen text and the checks that use it
    $checks = $null
    if (-not $NoOcr) {
        Write-Step "Text: reading the text in $($frameList.Count) frames (Windows OCR)"
        Invoke-FrameOcr $frameList $work
        Write-Step 'Text: spelling, reading time, numbers and safe areas'
        $checks = [pscustomobject]@{
            Spelling = Invoke-SpellCheck $frameList $narr.Lines $Project $work
            Reading  = $(if ($ctx.Mode -eq 'video') { , @(Test-ReadingTime $frameList $script:SceneRuns $ctx.Duration) } else { $null })
            Numbers  = $(if ($narr.Matched) { , @(Test-NumberMatch $frameList $narr.Lines) } else { $null })
            Safe     = Test-SafeAreas $frameList $ctx.Width $ctx.Height
        }
    }

    # Changes since the previous review
    $sigSize = Get-SignatureSize $ctx.Width $ctx.Height
    Set-FrameSignatures $frameList $work $sigSize[0] $sigSize[1]
    $chg = $null
    if ($previous) {
        Write-Step "Changes: comparing with the review made $($previous.Made)"
        $chg = Compare-WithPrevious $frameList $previous $sigSize[0] $sigSize[1] $OutDir
    }

    # Summary rows shared by report.md and the PDF cover.
    $reasons = @{}
    foreach ($f in $frameList) { foreach ($w in ($f.Why -split ', ')) { $reasons[$w] = 1 + [int]$reasons[$w] } }
    $frameLine = '{0} ({1})' -f $frameList.Count, (($reasons.Keys | Sort-Object | ForEach-Object { "$($reasons[$_]) $_" }) -join ', ')
    $summary = @(
        , @('Length', ('{0} ({1:0.00} s)' -f (Format-Time $ctx.Duration), $ctx.Duration))
        , @('Video', $videoLine)
        , @('Audio', $audioLine)
        , @('Frames', $frameLine)
    )
    if ($audio) {
        $summary += , @('Integrated loudness', ('{0} (loudness range {1:0.0} LU)' -f (Format-Db $audio.Integrated 'LUFS'), $audio.Lra))
        $summary += , @('Peaks', ('true peak {0}; sample peak {1} at {2}' -f (Format-Db $audio.TruePeak 'dBTP'), (Format-Db $audio.Scan.SamplePeakDb), (Format-Time $audio.Scan.SamplePeakTime)))
        $summary += , @("Silences over $MinSilence s", "$($audio.Silences.Count)")
        $summary += , @('Possible clicks or pops', "$($audio.Clicks.Count)")
        $summary += , @('Clipped samples', "$($audio.Scan.ClippedSamples)")
    }
    $narrLine = if ($narr.Matched) { '{0} of {1} lines placed ({2})' -f $narr.Matched, @($narr.Lines).Count, $narr.Group.Source }
    elseif ($narr.Group) { "found but not placed in time ($($narr.Group.Source))" } else { 'none found' }
    $summary += , @('Narration', $narrLine)
    if ($checks) {
        $summary += , @('On-screen text', ('{0} frames read; {1} possible spelling mistake(s)' -f @($frameList | Where-Object { $_.Text }).Count, @($checks.Spelling.Words).Count))
        if ($null -ne $checks.Reading) { $summary += , @('Too quick to read', ('{0} of {1} slides (at {2} words/s)' -f @($checks.Reading | Where-Object { $_.Worst }).Count, @($checks.Reading).Count, $WordsPerSecond)) }
        if ($null -ne $checks.Numbers) { $summary += , @('Spoken numbers not on screen', ('{0} of {1} lines with numbers' -f @($checks.Numbers | Where-Object { $_.Missing.Count }).Count, @($checks.Numbers).Count)) }
        if ($null -ne $checks.Safe) { $summary += , @('Text in Shorts safe-area margins', "$(@($checks.Safe.Hits).Count)") }
    }
    if ($chg) { $summary += , @('Changed since last review', ('{0} of {1} frames' -f @($chg.Changed).Count, $frameList.Count)) }
    $ctx.Summary = $summary

    $pdfInfo = $null; $changesPdfInfo = $null
    if (-not $NoPdf) {
        $ctx.CoverHtml = Build-Cover ([pscustomobject]$ctx) $audio $narr $frameList $checks $chg
        $pdfInfo = New-ReviewPdf ([pscustomobject]$ctx) $frameList $OutDir $work
    }
    if ($ChangesPdf) {
        if (-not $chg) { Add-Warning 'No previous review to compare with, so no changes PDF was made. Run the review once, render again, then run it with -ChangesPdf.' }
        elseif (-not @($chg.Changed).Count) { Add-Warning 'No frames changed since the last review, so no changes PDF was made.' }
        else {
            $cctx = [pscustomobject]$ctx
            $cctx.CoverHtml = "<h1>Changes: $(Get-Html $ctx.Title)</h1><p class='muted'>$(Get-Html $ctx.SourceLine) &middot; made $(Get-Date -Format 'yyyy-MM-dd HH:mm') with review-video.ps1</p>" + (Build-ChangesHtml $chg)
            $changesPdfInfo = New-ReviewPdf $cctx $chg.Changed $OutDir $work 'changes'
        }
    }

    Write-Step 'Writing report.md and review.json'
    $report = Join-Path $OutDir 'report.md'
    Write-Utf8 $report (Build-Report ([pscustomobject]$ctx) $audio $narr $frameList $pdfInfo $checks $chg $changesPdfInfo)
    Write-ReviewJson (Join-Path $OutDir 'review.json') ([pscustomobject]$ctx) $frameList $sigSize[0] $sigSize[1]

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host "  Report: $report"
    Write-Host "  Frames: $framesDir ($($frameList.Count))"
    if ($pdfInfo) { Write-Host ('  PDF:    {0} ({1:0.0} MB)' -f $pdfInfo.Path, $pdfInfo.SizeMB) }
    if ($changesPdfInfo) { Write-Host ('  Changes PDF: {0} ({1:0.0} MB)' -f $changesPdfInfo.Path, $changesPdfInfo.SizeMB) }
    if ($audio) {
        Write-Host ('  Audio:  {0}, true peak {1}, {2} silence(s) over {3} s, {4} possible click(s), {5} clipped sample(s)' -f `
            (Format-Db $audio.Integrated 'LUFS'), (Format-Db $audio.TruePeak 'dBTP'), $audio.Silences.Count, $MinSilence, $audio.Clicks.Count, $audio.Scan.ClippedSamples)
    }
    Write-Host "  Narration: $narrLine"
    if ($checks) {
        $line = '  Text:   {0} possible spelling mistake(s)' -f @($checks.Spelling.Words).Count
        if ($null -ne $checks.Reading) { $line += ', {0} slide(s) too quick to read' -f @($checks.Reading | Where-Object { $_.Worst }).Count }
        if ($null -ne $checks.Numbers) { $line += ', {0} line(s) with a spoken number not on screen' -f @($checks.Numbers | Where-Object { $_.Missing.Count }).Count }
        if ($null -ne $checks.Safe) { $line += ', {0} text item(s) in Shorts safe-area margins' -f @($checks.Safe.Hits).Count }
        Write-Host $line
    }
    if ($chg) { Write-Host ('  Changes: {0} of {1} frames changed since the review made {2}' -f @($chg.Changed).Count, $frameList.Count, $previous.Made) }
    if ($script:Warnings.Count) { Write-Host "  $($script:Warnings.Count) warning(s); see the top of report.md." -ForegroundColor Yellow }
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        $where = if ($_.InvocationInfo.ScriptName) { [IO.Path]::GetFileName($_.InvocationInfo.ScriptName) } else { 'review-video.ps1' }
        Write-Host "  (at $where line $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor DarkGray
    }
    $exitCode = 1
}
finally {
    if ($work -and (Test-Path -LiteralPath $work)) {
        if ($KeepWork) { Write-Host "Work folder kept: $work" } else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [Threading.Thread]::CurrentThread.CurrentCulture = $script:OldCulture
}
exit $exitCode
