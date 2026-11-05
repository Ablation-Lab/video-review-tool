# Key-frames PDF for review-video.ps1 (-KeyFramesPdf): a small PDF of about 15 to 20 frames, one
# fully built frame per scene plus the frames flagged as findings, to attach to a chat in place of
# the full contact sheet. Dot-sourced by review-video.ps1, which supplies the helpers used here.

$script:KeyFramesTarget = 20
$script:KeyFramesMin = 15

function Format-Clock([double]$t) {
    # 83.4 -> 01:23, 3725.1 -> 1:02:05
    $t = [Math]::Max([Math]::Floor($t), 0)
    $h = [Math]::Floor($t / 3600); $m = [Math]::Floor(($t - $h * 3600) / 60); $s = $t - $h * 3600 - $m * 60
    if ($h -gt 0) { return '{0}:{1:00}:{2:00}' -f $h, $m, $s }
    return '{0:00}:{1:00}' -f $m, $s
}

function Format-SceneName([string]$caps) {
    # "A REVIEWER WHO DIDN'T WRITE THE CODE" -> "A Reviewer Who Didn't Write the Code"
    $small = 'a', 'an', 'and', 'as', 'at', 'but', 'by', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'vs'
    $words = @($caps.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $out = for ($i = 0; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($i -gt 0 -and $small -contains $w) { $w } else { $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1) }
    }
    return ($out -join ' ')
}

function Get-SceneBadge([string[]]$lines) {
    # Slide videos often carry a footer badge such as "03 / SIZE DEPENDS ON THE TASK". OCR returns
    # it as a two-digit line followed by one or more capital-letter lines, near the end of the
    # frame's lines; the last such group is used. Returns $null if there is none.
    $l = @($lines | ForEach-Object { "$_".Trim() })
    $cap = '^[\p{Lu}\d ,.''\u2019&:?!+-]{2,}$'
    for ($i = $l.Count - 2; $i -ge 0; $i--) {
        if ($l[$i] -match '^\d{2}$' -and $l[$i + 1] -cmatch $cap -and $l[$i + 1] -cmatch '\p{Lu}{2}') {
            $parts = @(); $k = $i + 1
            while ($k -lt $l.Count -and $parts.Count -lt 8 -and $l[$k] -cmatch $cap -and $l[$k] -notmatch '^\d+$') { $parts += $l[$k]; $k++ }
            return [pscustomobject]@{ No = [int]$l[$i]; Name = (($parts -join ' ') -replace '\s+', ' ').Trim() }
        }
    }
    return $null
}

function Resolve-SceneBadges($frames) {
    # Gives each frame a Badge ($null if none) once OCR slips are removed. A scene is a badge name
    # seen on at least 2 frames (a name cut short by OCR joins the longer name it starts); its
    # number is the one read most often (OCR sometimes reads "10" as "13" on a few frames); and
    # scenes must run in number order through the video, the best-attested first.
    foreach ($f in $frames) { $f | Add-Member -NotePropertyName Badge -NotePropertyValue $null -Force }
    $raw = @($frames | ForEach-Object { $b = Get-SceneBadge $_.Lines; if ($b) { [pscustomobject]@{ Frame = $_; No = $b.No; Name = $b.Name } } })
    $names = @($raw | ForEach-Object { $_.Name } | Sort-Object -Unique)
    foreach ($r in $raw) {
        $longer = @($names | Where-Object { $_.Length -gt $r.Name.Length -and $_.StartsWith($r.Name) } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($longer.Count) { $r.Name = $longer[0] }
    }
    $cands = @()
    foreach ($g in @($raw | Group-Object Name | Where-Object { $_.Count -ge 2 })) {
        $no = [int]($g.Group | Group-Object No | Sort-Object Count -Descending | Select-Object -First 1).Name
        $times = @($g.Group | ForEach-Object { $_.Frame.Time } | Sort-Object)
        $cands += [pscustomobject]@{ No = $no; Name = $g.Name; Count = $g.Count; Mid = $times[[Math]::Floor($times.Count / 2)]; Group = $g.Group }
    }
    $keep = @()
    foreach ($c in @($cands | Sort-Object Count -Descending)) {
        $ok = $true
        foreach ($k in $keep) { if ($k.No -eq $c.No -or (($k.No -lt $c.No) -ne ($k.Mid -lt $c.Mid))) { $ok = $false; break } }
        if ($ok) { $keep += $c }
    }
    foreach ($k in $keep) { foreach ($r in $k.Group) { $r.Frame.Badge = [pscustomobject]@{ No = $k.No; Name = $k.Name } } }
    return @($keep | Sort-Object No)
}

function Select-KeyFrames($frames, [double]$duration) {
    # Returns the chosen frames in time order, each with a Label (scene) and Findings.
    $fa = @($frames | Sort-Object Time)
    if (-not $fa.Count) { return @() }
    $found = @(Resolve-SceneBadges $fa)
    $badged = @($fa | Where-Object { $_.Badge })
    $nums = @($found | ForEach-Object { $_.No })
    $sel = New-Object System.Collections.Generic.List[object]
    $add = {
        param($frame, $label)
        $sel.Add([pscustomobject]@{ Frame = $frame; Label = $label; Findings = (New-Object System.Collections.Generic.List[string]); Kind = '' })
    }

    if ($nums.Count -ge 3) {
        # One entry per scene number: its last 'end of scene' frame (the finished slide just before
        # the change), or its last frame if none was taken.
        $scenes = @()
        foreach ($n in $nums) {
            $g = @($badged | Where-Object { $_.Badge.No -eq $n })
            $ends = @($g | Where-Object { $_.Why -match 'end of scene' })
            $pick = if ($ends.Count) { $ends[-1] } else { $g[-1] }
            $nm = $g[0].Badge.Name
            $scenes += [pscustomobject]@{ Frame = $pick; Label = ('Scene {0}: {1}' -f $n, (Format-SceneName $nm)) }
        }
        $limit = $script:KeyFramesTarget - 2
        if ($scenes.Count -gt $limit) {
            $scenes = @(for ($k = 0; $k -lt $limit; $k++) { $scenes[[Math]::Floor($k * $scenes.Count / $limit)] })
        }
        foreach ($s in $scenes) { & $add $s.Frame $s.Label }
    } else {
        # No clear scenes: frames spread evenly over the video, preferring finished slides.
        $pool = @($fa | Where-Object { $_.Why -match 'end of scene' })
        if ($pool.Count -lt $script:KeyFramesMin) { $pool = $fa }
        $count = [Math]::Min(16, $pool.Count)
        $used = @{}
        for ($k = 0; $k -lt $count; $k++) {
            $t = ($k + 0.5) * $duration / $count
            $best = $pool | Where-Object { -not $used[$_.Index] } | Sort-Object { [Math]::Abs($_.Time - $t) } | Select-Object -First 1
            if (-not $best) { continue }
            $used[$best.Index] = $true
            $first = @($best.Lines | Where-Object { "$_".Trim() }) | Select-Object -First 1
            $lab = if ($first) { ("$first").Trim() } else { 'No text found' }
            if ($lab.Length -gt 70) { $lab = $lab.Substring(0, 70) + '...' }
            & $add $best $lab
        }
    }

    # Findings: frames the review flagged, one kind at a time so every kind is represented, and
    # not the same slide twice. A finding on a frame already chosen is added to that frame.
    $cands = @{ blank = @(); number = @(); safe = @(); spelling = @(); reading = @() }
    $noText = @($fa | Where-Object { -not @($_.Lines | Where-Object { "$_".Trim() }).Count -and $_.Time -ge 1 -and $_.Time -le $duration - 1 -and $_.Why -notmatch 'last frame|scene change' })
    if ($noText.Count -le [Math]::Max(3, $fa.Count * 0.1)) {
        $cands.blank = @($noText | ForEach-Object { [pscustomobject]@{ Frame = $_; Text = 'no text found: possible blank frame'; Rank = 0 } })
    }
    foreach ($f in $fa) {
        foreach ($fl in @($f.Flags | Select-Object -Unique)) {
            if ($fl -match '^number') { $cands.number += [pscustomobject]@{ Frame = $f; Text = $fl; Rank = 0 } }
            elseif ($fl -match '^safe area') { $cands.safe += [pscustomobject]@{ Frame = $f; Text = $fl; Rank = 0 } }
            elseif ($fl -match '^spelling') { $cands.spelling += [pscustomobject]@{ Frame = $f; Text = $fl; Rank = 0 } }
            elseif ($fl -match '^reading time: slide \d+ needs ([\d.]+) s, shows ([\d.]+) s') {
                $cands.reading += [pscustomobject]@{ Frame = $f; Text = $fl; Rank = -([double]$Matches[1] - [double]$Matches[2]) }
            }
        }
    }
    $slots = [Math]::Max(2, $script:KeyFramesTarget - $sel.Count)
    $taken = New-Object System.Collections.Generic.List[object]
    $queues = @{}
    foreach ($k in $cands.Keys) { $queues[$k] = @($cands[$k] | Sort-Object Rank, { $_.Frame.Time }) }
    $progress = $true
    while ($progress -and $taken.Count -lt $slots) {
        $progress = $false
        foreach ($k in 'blank', 'number', 'safe', 'spelling', 'reading') {
            if ($taken.Count -ge $slots) { break }
            while ($queues[$k].Count) {
                $c = $queues[$k][0]; $queues[$k] = @($queues[$k] | Select-Object -Skip 1)
                $f = $c.Frame
                $same = @($sel | Where-Object { [Math]::Abs($_.Frame.Time - $f.Time) -lt 6 -and (($_.Frame.Lines -join '|') -eq ($f.Lines -join '|')) } | Select-Object -First 1)
                if ($same.Count) { if ($same[0].Findings -notcontains $c.Text) { $same[0].Findings.Add($c.Text) }; $progress = $true; continue }
                if (@($taken | Where-Object { $_.Kind -eq $k -and [Math]::Abs($_.Frame.Time - $f.Time) -lt 6 }).Count) { continue }
                $e = [pscustomobject]@{ Frame = $f; Label = ''; Findings = (New-Object System.Collections.Generic.List[string]); Kind = $k }
                $e.Findings.Add($c.Text)
                $taken.Add($e); $sel.Add($e); $progress = $true
                break
            }
        }
    }
    # Name the scene of each finding frame from the nearest earlier badge.
    foreach ($e in $sel) {
        if ($e.Label) { continue }
        $b = $e.Frame.Badge
        if (-not $b -and $e.Kind -eq 'blank') { $b = @($badged | Where-Object { $_.Time -gt $e.Frame.Time -and $_.Time -le $e.Frame.Time + 4 } | Select-Object -First 1 | ForEach-Object { $_.Badge }) | Select-Object -First 1 }
        if (-not $b) { $b = @($badged | Where-Object { $_.Time -le $e.Frame.Time } | Select-Object -Last 1 | ForEach-Object { $_.Badge }) | Select-Object -First 1 }
        if (-not $b) { $b = @($badged | Select-Object -First 1 | ForEach-Object { $_.Badge }) | Select-Object -First 1 }
        $e.Label = if ($b -and $nums.Count -ge 3) { 'Scene {0}: {1}' -f $b.No, (Format-SceneName $b.Name) } else { 'Flagged frame' }
    }

    # Pad to the minimum with evenly spread finished slides, filling the biggest gaps first.
    $pool = @($fa | Where-Object { $_.Why -match 'end of scene' })
    if (-not $pool.Count) { $pool = $fa }
    while ($sel.Count -lt $script:KeyFramesMin -and $sel.Count -lt $pool.Count) {
        $times = @(0) + @($sel | ForEach-Object { $_.Frame.Time } | Sort-Object) + @($duration)
        $gap = 0; $mid = 0
        for ($i = 1; $i -lt $times.Count; $i++) { if ($times[$i] - $times[$i - 1] -gt $gap) { $gap = $times[$i] - $times[$i - 1]; $mid = ($times[$i] + $times[$i - 1]) / 2 } }
        $have = @($sel | ForEach-Object { $_.Frame.Index })
        $best = $pool | Where-Object { $have -notcontains $_.Index } | Sort-Object { [Math]::Abs($_.Time - $mid) } | Select-Object -First 1
        if (-not $best) { break }
        $b = $best.Badge
        $lab = if ($b -and $nums.Count -ge 3) { 'Scene {0}: {1}' -f $b.No, (Format-SceneName $b.Name) } else { 'Evenly spread' }
        & $add $best $lab
    }
    return @($sel | Sort-Object { $_.Frame.Time })
}

function Write-KeyFramesHtml([string]$htmlPath, $ctx, $picks, [string[]]$thumbNames, [string]$thumbRel) {
    $ar = [Math]::Max(1, $ctx.Width) / [Math]::Max(1, $ctx.Height)
    if ($ar -ge 1) { $orient = 'landscape'; $pageH = 194; $shotH = 150 } else { $orient = 'portrait'; $pageH = 281; $shotH = 214 }
    $css = @"
@page { size: A4 $orient; margin: 8mm; }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Arial, sans-serif; color: #111; margin: 0; }
.page { height: ${pageH}mm; page-break-after: always; overflow: hidden; display: flex; flex-direction: column; }
.page:last-child { page-break-after: auto; }
.head { height: 6mm; font-size: 8pt; color: #555; display: flex; justify-content: space-between; }
.shot { width: 100%; height: ${shotH}mm; object-fit: contain; background: #000; border: 0.2mm solid #ccc; display: block; }
.ts { font-size: 13pt; font-weight: 700; margin-top: 2mm; } .ts .scene { font-weight: 600; }
.find { font-size: 10pt; font-weight: 600; color: #a40000; margin-top: 0.8mm; }
.meta { font-size: 8pt; color: #666; margin-top: 0.8mm; }
.ocr { font-size: 8pt; color: #24476b; margin-top: 0.8mm; max-height: 10mm; overflow: hidden; }
"@
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>$(Get-Html $ctx.Title) key frames</title><style>$css</style></head><body>")
    $n = @($picks).Count
    for ($i = 0; $i -lt $n; $i++) {
        $p = $picks[$i]; $f = $p.Frame
        [void]$sb.Append("<div class='page'><div class='head'><span>$(Get-Html $ctx.Title) &middot; key frames</span><span>$($i + 1) of $n</span></div>")
        [void]$sb.Append("<img class='shot' src='$thumbRel/$($thumbNames[$i])'>")
        [void]$sb.Append("<div class='ts'>$(Format-Clock $f.Time) &nbsp;&middot;&nbsp; <span class='scene'>$(Get-Html $p.Label)</span></div>")
        foreach ($fd in $p.Findings) { [void]$sb.Append("<div class='find'>Finding: $(Get-Html $fd)</div>") }
        [void]$sb.Append("<div class='meta'>frame #$($f.Index) at $(Format-Time $f.Time) &middot; $(Get-Html $f.Why)</div>")
        $txt = (@($f.Lines | Where-Object { "$_".Trim() }) -join ' / ')
        if ($txt.Length -gt 220) { $txt = $txt.Substring(0, 220) + '...' }
        if ($txt) { [void]$sb.Append("<div class='ocr'>On screen: $(Get-Html $txt)</div>") }
        [void]$sb.Append('</div>')
    }
    [void]$sb.Append('</body></html>')
    Write-Utf8 $htmlPath $sb.ToString()
}

function New-KeyFramesPdf($ctx, $frames, [string]$outDir, [string]$work) {
    $browser = Find-Browser
    if (-not $browser) { throw 'Microsoft Edge or Google Chrome is needed to make the PDF and neither was found.' }
    $picks = @(Select-KeyFrames $frames $ctx.Duration)
    if (-not $picks.Count) { throw 'No frames to make a key-frames PDF from.' }
    $pdf = Join-Path $outDir 'key-frames.pdf'
    $limit = $KeyFramesMaxMB * 1MB
    $portrait = $ctx.Height -gt $ctx.Width
    $chosen = @($picks | ForEach-Object { $_.Frame })
    $size = 0; $side = 0
    foreach ($s in @(@(1280, 3), @(1024, 4), @(800, 5), @(640, 6), @(480, 8), @(320, 10))) {
        $side = $s[0]
        Write-Step ("Key frames: {0} frames at {1} px (long side)" -f $picks.Count, $side)
        $tag = "keyframes-$side"
        $names = New-Thumbs $chosen (Join-Path $work "thumbs-$tag") $side $s[1] $portrait
        $html = Join-Path $work "$tag.html"
        Write-KeyFramesHtml $html $ctx $picks $names "thumbs-$tag"
        if (Test-Path -LiteralPath $pdf) { Remove-Item -LiteralPath $pdf -Force }
        $r = Invoke-Tool $browser @('--headless', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
            '--no-pdf-header-footer', '--print-to-pdf-no-header', "--user-data-dir=$(Join-Path $work "browser-profile-$tag")",
            "--print-to-pdf=$pdf", ([Uri]$html).AbsoluteUri) 'PDF printing' -AllowFail -NoCapture
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
        if (-not $ready) { throw "The browser did not finish writing the key-frames PDF within 3 minutes ($browser, exit code $($r.Code))." }
        $size = (Get-Item -LiteralPath $pdf).Length
        if ($size -le $limit) { break }
        Write-Host ("    {0:0.0} MB is over the {1} MB limit; trying smaller frames" -f ($size / 1MB), $KeyFramesMaxMB)
    }
    if ($size -gt $limit) { Add-Warning ("The key-frames PDF is {0:0.0} MB, over the {1} MB limit even with the smallest frames." -f ($size / 1MB), $KeyFramesMaxMB) }
    return [pscustomobject]@{ Path = $pdf; SizeMB = $size / 1MB; LongSide = $side; Count = $picks.Count; Picks = $picks }
}

function Read-ExistingPack([string]$outDir) {
    # The frames of an earlier review in $outDir, or $null if there is no complete one to reuse.
    $json = Join-Path $outDir 'review.json'
    if (-not (Test-Path -LiteralPath $json)) { return $null }
    try { $j = [IO.File]::ReadAllText($json) | ConvertFrom-Json } catch { return $null }
    if (-not $j.frames -or -not $j.width) { return $null }
    # Flags: stored in review.json by newer versions, otherwise read from the report's table.
    $flagsByIndex = @{}
    $report = Join-Path $outDir 'report.md'
    if (Test-Path -LiteralPath $report) {
        foreach ($line in [IO.File]::ReadAllLines($report)) {
            if ($line -match '^\|\s*(\d+)\s*\|.*\|\s*([^|]*?)\s*\|\s*$' -and $line -match '\(frames/') {
                $flagsByIndex[[int]$Matches[1]] = @($Matches[2] -split '; ' | Where-Object { $_ -and $_ -notmatch '^changed since last review' })
            }
        }
    }
    $frames = @()
    foreach ($f in @($j.frames)) {
        $path = Join-Path (Join-Path $outDir 'frames') $f.name
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $fl = if ($f.PSObject.Properties['flags']) { @($f.flags) } elseif ($flagsByIndex.ContainsKey([int]$f.index)) { $flagsByIndex[[int]$f.index] } else { @() }
        $frames += [pscustomobject]@{ Index = [int]$f.index; Time = [double]$f.time; Name = $f.name; Path = $path; Why = $f.why
            Lines = @($f.lines); Flags = $fl }
    }
    $ctx = [pscustomobject]@{ Title = $j.source; Width = [int]$j.width; Height = [int]$j.height; Duration = [double]$j.duration }
    return [pscustomobject]@{ Ctx = $ctx; Frames = $frames }
}
