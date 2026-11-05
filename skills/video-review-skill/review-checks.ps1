# On-screen text checks and render-to-render comparison for review-video.ps1, which dot-sources
# this file. Uses Windows' built-in OCR and spell checker through windows-text.ps1 (no installs).
#
#   OCR             every frame's text, with word positions
#   spelling        words the Windows spell checker rejects (after filtering OCR noise)
#   reading time    slides whose new text is on screen for less time than it takes to read
#   numbers         numbers in a narration line that aren't on screen while the line plays
#   safe areas      text inside the margins YouTube Shorts covers (vertical 9:16 videos)
#   changes         frames whose picture differs from every frame of the previous review

# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------

function Write-ConcatList($frames, [string]$file) {
    # ffmpeg concat-demuxer list, so one ffmpeg run can process every frame.
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $frames) {
        $p = $f.Path.Replace('\', '/').Replace("'", "'\''")
        [void]$sb.Append("file '$p'`nduration 0.04`n")
    }
    Write-Utf8 $file $sb.ToString()
}

function Get-NormText([string]$t) {
    # For comparing lines: lower case, letters and digits only.
    if (-not $t) { return '' }
    return (($t.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', ' ').Trim())
}

function Get-WordCount([string]$t) {
    # Words to read: tokens that start with a letter. Bare numbers (grid IDs, counters) read at a
    # glance, so they don't count.
    if (-not $t) { return 0 }
    return ([regex]::Matches($t, "\p{L}[\p{L}\p{Nd}]*(?:['\u2019][\p{L}]+)?")).Count
}

function Invoke-WindowsText([string]$mode, [string]$inFile, [string]$outFile, [string]$what) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { throw "Windows PowerShell 5.1 ($ps) is needed for Windows OCR and spelling, and was not found. Run with -NoOcr." }
    $helper = Join-Path $PSScriptRoot 'windows-text.ps1'
    if (-not (Test-Path -LiteralPath $helper)) { throw "windows-text.ps1 is missing; it must sit next to review-video.ps1 ($helper)." }
    $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-Mode', $mode, '-In', $inFile, '-Out', $outFile)
    if ($OcrLanguage) { $a += @('-Language', $OcrLanguage) }
    [void](Invoke-Tool $ps $a $what)
    if (-not (Test-Path -LiteralPath $outFile)) { throw "$what produced no output file." }
    return ([IO.File]::ReadAllText($outFile) | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------------------------
# Signatures and OCR
# ---------------------------------------------------------------------------------------------

function Get-SignatureSize([int]$w, [int]$h) {
    $ar = $w / [Math]::Max(1, $h)
    if ($ar -ge 1.2) { return @(128, 72) }
    if ($ar -le 0.83) { return @(72, 128) }
    return @(96, 96)
}

function Set-FrameSignatures($frames, [string]$work, [int]$sw, [int]$sh) {
    # A small greyscale copy of every frame (one byte per pixel), from one ffmpeg run.
    $list = Join-Path $work 'sig-list.txt'
    $raw = Join-Path $work 'signatures.raw'
    Write-ConcatList $frames $list
    [void](Invoke-Tool $script:Ffmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', $list,
            '-vf', "scale=${sw}:${sh}:flags=area,format=gray", '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'gray', $raw) 'frame signatures')
    $bytes = [IO.File]::ReadAllBytes($raw)
    $n = $sw * $sh
    $fa = @($frames)
    if ($bytes.Length -ne $n * $fa.Count) { throw "Frame signatures: expected $($n * $fa.Count) bytes, got $($bytes.Length)." }
    for ($i = 0; $i -lt $fa.Count; $i++) {
        $sig = New-Object byte[] $n
        [Array]::Copy($bytes, $i * $n, $sig, 0, $n)
        $fa[$i].Sig = $sig
    }
}

function ConvertTo-OcrLines($res, [double]$scale = 1) {
    # $scale maps word boxes from a resized copy back to the frame's own pixels.
    $lines = @()
    foreach ($l in @($res.lines)) {
        if (-not $l -or -not $l.text) { continue }
        # OCR puts a space before some apostrophes ("hasn 't").
        $text = ($l.text -replace "(\p{L}) (['\u2019])(t|s|re|ve|ll|d|m)\b", '$1$2$3').Trim()
        $ws = @($l.words)
        if ($scale -ne 1) {
            $ws = @($ws | ForEach-Object { [pscustomobject]@{ text = $_.text; x = [int]($_.x * $scale); y = [int]($_.y * $scale); w = [int]($_.w * $scale); h = [int]($_.h * $scale) } })
        }
        $x1 = ($ws | ForEach-Object { $_.x } | Measure-Object -Minimum).Minimum
        $y1 = ($ws | ForEach-Object { $_.y } | Measure-Object -Minimum).Minimum
        $x2 = ($ws | ForEach-Object { $_.x + $_.w } | Measure-Object -Maximum).Maximum
        $y2 = ($ws | ForEach-Object { $_.y + $_.h } | Measure-Object -Maximum).Maximum
        $lines += [pscustomobject]@{ Text = $text; Words = $ws; X = $x1; Y = $y1; W = $x2 - $x1; H = $y2 - $y1 }
    }
    return $lines
}

function Merge-OcrLines($a, $b) {
    # Keeps the reading with more words, then adds lines from the other that don't overlap it.
    $wa = 0; foreach ($l in @($a)) { $wa += @($l.Words).Count }
    $wb = 0; foreach ($l in @($b)) { $wb += @($l.Words).Count }
    if ($wb -gt $wa) { $t = $a; $a = $b; $b = $t }
    $out = @($a)
    foreach ($l in @($b)) {
        $overlap = $false
        foreach ($k in @($a)) {
            $ix = [Math]::Min($l.X + $l.W, $k.X + $k.W) - [Math]::Max($l.X, $k.X)
            $iy = [Math]::Min($l.Y + $l.H, $k.Y + $k.H) - [Math]::Max($l.Y, $k.Y)
            if ($ix -gt 0 -and $iy -gt 0 -and ($ix * $iy) -gt 0.3 * [Math]::Min($l.W * $l.H, $k.W * $k.H)) { $overlap = $true; break }
        }
        if (-not $overlap) { $out += $l }
    }
    return $out
}

function Invoke-FrameOcr($frames, [string]$work) {
    # Each frame is read three times and the readings are merged: as it is (best for small text),
    # with its colours inverted, and inverted at half size. Windows OCR reads dark text on light
    # backgrounds best, and on dark slides it misses large or coloured headline text at full size
    # that it reads fine once inverted and halved.
    $fa = @($frames)
    $negDir = Join-Path $work 'ocr-inverted'
    New-Item -ItemType Directory -Force -Path $negDir | Out-Null
    $listIn = Join-Path $work 'ocr-concat.txt'
    Write-ConcatList $fa $listIn
    [void](Invoke-Tool $script:Ffmpeg @('-hide_banner', '-nostdin', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', $listIn,
            '-filter_complex', 'negate,split[full][h];[h]scale=trunc(iw/4)*2:-2:flags=area[half]',
            '-map', '[full]', '-fps_mode', 'passthrough', (Join-Path $negDir 'n%05d.png'),
            '-map', '[half]', '-fps_mode', 'passthrough', (Join-Path $negDir 'h%05d.png')) 'inverted copies for OCR')
    $neg = @(Get-ChildItem -LiteralPath $negDir -Filter 'n*.png' | Sort-Object Name | ForEach-Object { $_.FullName })
    $half = @(Get-ChildItem -LiteralPath $negDir -Filter 'h*.png' | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($neg.Count -ne $fa.Count -or $half.Count -ne $fa.Count) { throw "Made $($neg.Count) and $($half.Count) inverted copies for $($fa.Count) frames." }
    $list = Join-Path $work 'ocr-list.txt'
    $out = Join-Path $work 'ocr.json'
    Write-Utf8 $list (((@($fa | ForEach-Object { $_.Path }) + $neg + $half) -join "`n") + "`n")
    $res = @(Invoke-WindowsText 'ocr' $list $out 'Windows OCR')
    $n = $fa.Count
    if ($res.Count -ne 3 * $n) { throw "Windows OCR returned $($res.Count) results for $(3 * $n) images." }
    for ($i = 0; $i -lt $n; $i++) {
        $a = @(ConvertTo-OcrLines $res[$i])
        $b = @(ConvertTo-OcrLines $res[$n + $i])
        $c = @(ConvertTo-OcrLines $res[2 * $n + $i] 2)
        # Words each reading saw, for the spelling check: a real typo reads the same way in the
        # original and in an inverted copy.
        $fa[$i].TokA = @($a | ForEach-Object { Get-SpellTokens $_.Text })
        $fa[$i].TokB = @(@($b) + @($c) | ForEach-Object { Get-SpellTokens $_.Text })
        $lines = Merge-OcrLines (Merge-OcrLines $a $b) $c
        # Reading order: top to bottom, then left to right.
        $fa[$i].Lines = @($lines | Sort-Object @{ Expression = { [Math]::Round($_.Y / 40) } }, X)
        $fa[$i].Text = (@($fa[$i].Lines | ForEach-Object { $_.Text }) -join ' / ')
    }
}

# ---------------------------------------------------------------------------------------------
# Spelling
# ---------------------------------------------------------------------------------------------

# Punctuation trimmed from words, including curly quotes, ellipsis, bullets, pound and euro signs
# (written as character codes so this file stays plain ASCII for Windows PowerShell 5.1).
$script:QuoteChars = [char[]]@(39, 0x2019)
$script:TrimChars = [char[]](".,;:!?`"'()[]{}<>*#&+=~^%`$@|".ToCharArray() + [char[]]@(0x201C, 0x201D, 0x2018, 0x2019, 0x2026, 0x2022, 0x00B7, 0x00A3, 0x20AC))

function Get-SpellTokens([string]$text) {
    $out = @()
    foreach ($raw in ($text -split '\s+')) {
        $t = $raw.Trim($script:TrimChars)
        foreach ($part in ($t -split '[-/\u2013\u2014_]')) {
            $p = $part.Trim($script:QuoteChars)
            if ($p.Length -lt 4) { continue }                       # short words: mostly OCR noise and labels
            if ($p -notmatch "^\p{L}[\p{L}'\u2019]*$") { continue }      # digits or symbols: codes, IDs, numbers
            if ($p -cmatch '\p{Ll}\p{Lu}') { continue }             # camelCase: names and identifiers
            if ($p -cmatch '^\p{Lu}+$' -and $p.Length -le 5) { continue }  # short all-caps: acronyms
            $out += $p
        }
    }
    return $out
}

function Get-AllowedWords($narrLines, [string]$projectRoot) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in @($narrLines)) { foreach ($w in ([regex]::Matches([string]$l.Text, "\p{L}[\p{L}'\u2019]*") | ForEach-Object { $_.Value })) { [void]$set.Add($w) } }
    $files = @()
    if ($WordList) {
        if (-not (Test-Path -LiteralPath $WordList)) { throw "-WordList file not found: $WordList" }
        $files += (Resolve-Path -LiteralPath $WordList).Path
    }
    foreach ($d in @($projectRoot, $PSScriptRoot)) {
        if ($d) { $c = Join-Path $d 'review-words.txt'; if (Test-Path -LiteralPath $c) { $files += $c } }
    }
    foreach ($f in $files) {
        foreach ($line in [IO.File]::ReadAllLines($f)) { $w = $line.Trim(); if ($w -and -not $w.StartsWith('#')) { [void]$set.Add($w) } }
    }
    return [pscustomobject]@{ Set = $set; Files = $files }
}

function Invoke-SpellCheck($frames, $narrLines, [string]$projectRoot, [string]$work) {
    $allowed = Get-AllowedWords $narrLines $projectRoot
    $unique = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in $frames) {
        foreach ($l in $f.Lines) { foreach ($t in (Get-SpellTokens $l.Text)) { if (-not $allowed.Set.Contains($t)) { [void]$unique.Add($t) } } }
    }
    $result = [pscustomobject]@{ Checked = $unique.Count; Words = @(); AllowFiles = $allowed.Files; ReadOnce = @(); Typing = @() }
    if (-not $unique.Count) { return $result }
    $in = Join-Path $work 'spell-words.txt'; $out = Join-Path $work 'spell.json'
    Write-Utf8 $in ((@($unique) -join "`n") + "`n")
    $bad = Invoke-WindowsText 'spell' $in $out 'Windows spell check'
    $names = @($bad.PSObject.Properties | ForEach-Object { $_.Name })
    if (-not $names.Count) { return $result }
    # A rejected word counts only when both OCR readings of some frame (as it is, and inverted) saw
    # it: OCR misreads of small or stylised text rarely come out the same both ways, real typos do.
    $both = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in $frames) { foreach ($t in @($f.TokA)) { if (@($f.TokB) -ccontains $t) { [void]$both.Add($t) } } }
    $result.ReadOnce = @($names | Where-Object { -not $both.Contains($_) })
    $names = @($names | Where-Object { $both.Contains($_) })
    # Text being typed on screen shows part-words ("Revi" before "Reviewers"): skip a rejected word
    # that is the start of a longer word read in another frame.
    $all = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $frames) { foreach ($t in @($f.TokA) + @($f.TokB)) { [void]$all.Add($t) } }
    $result.Typing = @($names | Where-Object { $w = $_; @($all | Where-Object { $_.Length -gt $w.Length -and $_.StartsWith($w, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 })
    $names = @($names | Where-Object { $result.Typing -notcontains $_ })
    if (-not $names.Count) { return $result }
    $byWord = [ordered]@{}
    foreach ($n in $names) { $byWord[$n] = [pscustomobject]@{ Word = $n; Suggestions = @($bad.$n); Frames = New-Object System.Collections.Generic.List[int]; Line = '' } }
    foreach ($f in $frames) {
        $hit = @()
        foreach ($l in $f.Lines) {
            foreach ($t in (Get-SpellTokens $l.Text)) {
                if ($byWord.Contains($t)) {
                    $e = $byWord[$t]
                    if (-not $e.Frames.Contains($f.Index)) { $e.Frames.Add($f.Index) }
                    if (-not $e.Line) { $e.Line = $l.Text }
                    if ($hit -notcontains $t) { $hit += $t }
                }
            }
        }
        if ($hit.Count) { $f.Misspelt = $hit; $f.Flags.Add('spelling: ' + ($hit -join ', ')) }
    }
    $result.Words = @($byWord.Values)
    return $result
}

# ---------------------------------------------------------------------------------------------
# Reading time
# ---------------------------------------------------------------------------------------------

function Test-ReadingTime($frames, $runs, [double]$duration) {
    # Slides run from one scene change to the next. Text carried over from the previous slide
    # (headers, footers) is left out. Each new line counts from when it first appears (halfway
    # between the frame before and the first frame showing it); the slide is too quick if, from
    # any of those moments, the words still to read need more than 0.5 s longer than is left before
    # the slide ends (the margin allows for frames being sampled every few seconds).
    $bounds = @()
    $start = 0.0
    foreach ($r in @($runs)) {
        $end = if ($null -ne $r.Before) { $r.Before + 0.25 } else { $r.End }
        if ($end -gt $start + 0.1) { $bounds += , @($start, $end) }
        $start = $r.End
    }
    if ($duration -gt $start + 0.1) { $bounds += , @($start, $duration) }
    $slides = @()
    $prevNorms = New-Object 'System.Collections.Generic.HashSet[string]'
    $fa = @($frames | Sort-Object Time)
    $k = 0
    foreach ($b in $bounds) {
        $k++
        $sf = @($fa | Where-Object { $_.Time -ge $b[0] - 0.01 -and $_.Time -le $b[1] + 0.01 })
        $first = @{}; $wordsOf = @{}; $textOf = @{}; $boxOf = @{}
        $norms = New-Object 'System.Collections.Generic.HashSet[string]'
        $prevT = $b[0]
        foreach ($f in $sf) {
            foreach ($l in $f.Lines) {
                $n = Get-NormText $l.Text
                if (-not $n) { continue }
                [void]$norms.Add($n)
                if ($prevNorms.Contains($n) -or $first.ContainsKey($n)) { continue }
                # The same line read slightly differently in another frame (OCR varies) sits in the
                # same place: count it once, with its larger word count.
                $same = $null
                foreach ($bk in @($boxOf.Keys)) {
                    $o = $boxOf[$bk]
                    $ix = [Math]::Min($l.X + $l.W, $o.X + $o.W) - [Math]::Max($l.X, $o.X)
                    $iy = [Math]::Min($l.Y + $l.H, $o.Y + $o.H) - [Math]::Max($l.Y, $o.Y)
                    if ($ix -gt 0 -and $iy -gt 0 -and ($ix * $iy) -gt 0.6 * [Math]::Max($l.W * $l.H, $o.W * $o.H)) { $same = $bk; break }
                }
                if ($same) { $wordsOf[$same] = [Math]::Max($wordsOf[$same], (Get-WordCount $l.Text)); continue }
                $first[$n] = ($prevT + $f.Time) / 2
                $wordsOf[$n] = Get-WordCount $l.Text
                $textOf[$n] = $l.Text
                $boxOf[$n] = $l
            }
            $prevT = $f.Time
        }
        $total = 0; foreach ($v in $wordsOf.Values) { $total += $v }
        $worst = $null
        foreach ($t in (@($first.Values) | Sort-Object -Unique)) {
            $after = 0; foreach ($n in $first.Keys) { if ($first[$n] -ge $t - 0.001) { $after += $wordsOf[$n] } }
            $need = $after / $WordsPerSecond
            $avail = $b[1] - $t
            if ($need -gt $avail + 0.5 -and (-not $worst -or ($need - $avail) -gt ($worst.Need - $worst.Avail))) {
                $worst = [pscustomobject]@{ From = $t; Words = $after; Need = $need; Avail = $avail }
            }
        }
        $sample = @($first.Keys | Sort-Object { $first[$_] } | Select-Object -First 3 | ForEach-Object { $textOf[$_] }) -join ' / '
        # A slide with no new words (a fade, a blank gap) has nothing to read and is left out.
        if ($total -eq 0) { $prevNorms = $norms; continue }
        $slideNo = $slides.Count + 1
        $slides += [pscustomobject]@{ Index = $slideNo; Start = $b[0]; End = $b[1]; Words = $total; Worst = $worst; Sample = $sample
            Frames = @($sf | ForEach-Object { $_.Index }) }
        if ($worst) { foreach ($f in $sf) { $f.Flags.Add(('reading time: slide {0} needs {1:0.0} s, shows {2:0.0} s' -f $slideNo, $worst.Need, $worst.Avail)) } }
        $prevNorms = $norms
    }
    return $slides
}

# ---------------------------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------------------------

$script:NumUnits = @{ zero = 0; one = 1; two = 2; three = 3; four = 4; five = 5; six = 6; seven = 7; eight = 8; nine = 9; ten = 10
    eleven = 11; twelve = 12; thirteen = 13; fourteen = 14; fifteen = 15; sixteen = 16; seventeen = 17; eighteen = 18; nineteen = 19 }
$script:NumTens = @{ twenty = 20; thirty = 30; forty = 40; fifty = 50; sixty = 60; seventy = 70; eighty = 80; ninety = 90 }
$script:NumScales = @{ thousand = 1e3; million = 1e6; billion = 1e9 }

function Get-Numbers([string]$text, [double]$wordsFrom) {
    # Numbers written as digits (17, 3.7M, $2, 48%, 1,200) and as words (seventeen, three point
    # seven million). Number words below $wordsFrom are ignored unless they carry a scale word.
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $text) { return $out }
    $re = '(?<![\p{L}\d.,])([$\u00A3\u20AC])?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(?:\s?(%|percent\b|per cent\b|k\b|m\b|bn\b|thousand\b|million\b|billion\b))?(?![\p{L}\d])'
    foreach ($m in [regex]::Matches($text, $re, 'IgnoreCase')) {
        $num = [double](($m.Groups[2].Value -replace ',', '') + $(if ($m.Groups[3].Success) { '.' + $m.Groups[3].Value } else { '' }))
        $suffix = $m.Groups[4].Value.ToLowerInvariant()
        $scale = switch -regex ($suffix) { '^(k|thousand)$' { 1e3 } '^(m|million)$' { 1e6 } '^(bn|billion)$' { 1e9 } default { 1 } }
        $out.Add([pscustomobject]@{ Value = $num * $scale; Mantissa = $num; Text = $m.Value.Trim(); Word = $false })
    }
    # Words
    $toks = @([regex]::Matches($text.ToLowerInvariant(), '[a-z]+|[^a-z\s-]') | ForEach-Object { $_.Value })
    $cur = 0.0; $total = 0.0; $active = $false; $words = @(); $hasScale = $false; $last = ''
    $flush = {
        if ($active) {
            $v = $total + $cur
            if ($v -ge $wordsFrom -or $hasScale) { $out.Add([pscustomobject]@{ Value = $v; Mantissa = $(if ($hasScale -and $cur -eq 0) { $v / [Math]::Pow(10, [Math]::Floor([Math]::Log10([Math]::Max($v, 1)) / 3) * 3) } else { $v }); Text = ($words -join ' '); Word = $true }) }
        }
    }
    for ($i = 0; $i -lt $toks.Count; $i++) {
        $t = $toks[$i]
        if ($script:NumUnits.ContainsKey($t)) {
            if ($active -and ($last -eq 'unit')) { & $flush; $cur = 0; $total = 0; $words = @(); $hasScale = $false; $active = $false }
            $cur += $script:NumUnits[$t]; $active = $true; $words += $t; $last = 'unit'
        } elseif ($script:NumTens.ContainsKey($t)) {
            if ($active -and ($last -eq 'unit' -or $last -eq 'tens')) { & $flush; $cur = 0; $total = 0; $words = @(); $hasScale = $false; $active = $false }
            $cur += $script:NumTens[$t]; $active = $true; $words += $t; $last = 'tens'
        } elseif ($t -eq 'hundred' -and $active) {
            $cur = [Math]::Max($cur, 1) * 100; $words += $t; $last = 'hundred'
        } elseif ($script:NumScales.ContainsKey($t) -and $active) {
            $total += [Math]::Max($cur, 1) * $script:NumScales[$t]; $cur = 0; $hasScale = $true; $words += $t; $last = 'scale'
        } elseif ($t -eq 'point' -and $active -and $i + 1 -lt $toks.Count -and $script:NumUnits.ContainsKey($toks[$i + 1]) -and $script:NumUnits[$toks[$i + 1]] -lt 10) {
            $dec = ''; $words += $t
            while ($i + 1 -lt $toks.Count -and $script:NumUnits.ContainsKey($toks[$i + 1]) -and $script:NumUnits[$toks[$i + 1]] -lt 10) { $i++; $dec += [string]$script:NumUnits[$toks[$i]]; $words += $toks[$i] }
            $cur += [double]('0.' + $dec); $last = 'point'
        } elseif ($t -eq 'and' -and $active -and $i + 1 -lt $toks.Count -and ($script:NumUnits.ContainsKey($toks[$i + 1]) -or $script:NumTens.ContainsKey($toks[$i + 1])) -and $last -match 'hundred|scale') {
            $words += $t
        } else {
            & $flush; $cur = 0; $total = 0; $words = @(); $hasScale = $false; $active = $false; $last = ''
        }
    }
    & $flush
    return $out
}

function Test-NumberMatch($frames, $narrLines) {
    $fa = @($frames | Sort-Object Time)
    $results = @()
    $k = 0
    foreach ($l in @($narrLines)) {
        $k++
        if ($null -eq $l.Start) { continue }
        $spoken = @(Get-Numbers $l.Text $NumberWordsFrom)
        if (-not $spoken.Count) { continue }
        $win = @($fa | Where-Object { $_.Time -ge $l.Start - 0.5 -and $_.Time -le $l.End + 1.0 })
        if (-not $win.Count) { $mid = ($l.Start + $l.End) / 2; $win = @($fa | Sort-Object { [Math]::Abs($_.Time - $mid) } | Select-Object -First 1) }
        $screen = @(); foreach ($f in $win) { $screen += @(Get-Numbers $f.Text 0) }
        $missing = @(); $seen = @{}
        foreach ($n in $spoken) {
            if ($seen.ContainsKey([string]$n.Value)) { continue }
            $seen[[string]$n.Value] = 1
            $tol = 1e-6 * [Math]::Max(1, [Math]::Abs($n.Value))
            $ok = @($screen | Where-Object { [Math]::Abs($_.Value - $n.Value) -le $tol -or [Math]::Abs($_.Value - $n.Mantissa) -le 1e-6 -or [Math]::Abs($_.Mantissa - $n.Value) -le 1e-6 }).Count -gt 0
            if (-not $ok) { $missing += $n }
        }
        $results += [pscustomobject]@{ Line = $k; Start = $l.Start; End = $l.End; Text = $l.Text; Spoken = $spoken; Missing = $missing
            Screen = @($screen | ForEach-Object { $_.Text } | Select-Object -Unique); Frames = @($win | ForEach-Object { $_.Index }) }
        if ($missing.Count) {
            foreach ($f in $win) { $f.Flags.Add(('number: narration says {0}, not on screen (line {1})' -f (($missing | ForEach-Object { $_.Text }) -join ', '), $k)) }
        }
    }
    return $results
}

# ---------------------------------------------------------------------------------------------
# Shorts safe areas
# ---------------------------------------------------------------------------------------------

function Test-SafeAreas($frames, [int]$w, [int]$h) {
    $ar = $w / [Math]::Max(1, $h)
    if ($ar -lt 0.5 -or $ar -gt 0.6) { return $null }   # only vertical 9:16 (0.5625)
    $m = @($SafeMargins -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { [double]$_ })
    if ($m.Count -ne 4) { throw "-SafeMargins takes four numbers in pixels at 1080x1920: top,right,bottom,left (got '$SafeMargins')." }
    $top = $m[0] * $h / 1920; $right = $w - $m[1] * $w / 1080; $bottom = $h - $m[2] * $h / 1920; $left = $m[3] * $w / 1080
    $hits = [ordered]@{}
    foreach ($f in $frames) {
        $edgesHere = @()
        foreach ($l in $f.Lines) {
            $edges = @()
            if ($l.Y -lt $top) { $edges += 'top' }
            if ($l.Y + $l.H -gt $bottom) { $edges += 'bottom' }
            if ($l.X -lt $left) { $edges += 'left' }
            if ($l.X + $l.W -gt $right) { $edges += 'right' }
            if (-not $edges.Count) { continue }
            $key = (Get-NormText $l.Text) + '|' + ($edges -join ',')
            if (-not $hits.Contains($key)) { $hits[$key] = [pscustomobject]@{ Text = $l.Text; Edges = $edges; Frames = New-Object System.Collections.Generic.List[int]; First = $f.Time; Last = $f.Time } }
            $e = $hits[$key]; if (-not $e.Frames.Contains($f.Index)) { $e.Frames.Add($f.Index) }; $e.Last = $f.Time
            $edgesHere += $edges
        }
        if ($edgesHere.Count) { $f.Flags.Add('safe area: text in the ' + ((@($edgesHere | Select-Object -Unique)) -join ', ') + ' margin') }
    }
    return [pscustomobject]@{ Margins = $m; Box = @([int]$left, [int]$top, [int]$right, [int]$bottom); Hits = @($hits.Values) }
}

# ---------------------------------------------------------------------------------------------
# Changes since the previous review
# ---------------------------------------------------------------------------------------------

# Frame images a review saves in <OutDir>\frames, such as 0001_00-00-02.000_scene.png.
$script:FrameNamePattern = '^\d{4}_\d\d-\d\d-\d\d\.\d{3}_[a-z0-9]+\.png$'

function Get-ReviewFileNames([string]$dir) {
    # The files the review in $dir wrote there: report.md, review.json, key-frames.pdf, and
    # <name>-review.pdf and <name>-changes.pdf, with <name> taken from its review.json. Any other
    # file in the folder isn't the tool's, so it is never moved or deleted.
    $names = @('report.md', 'review.json', 'key-frames.pdf')
    $json = Join-Path $dir 'review.json'
    if (Test-Path -LiteralPath $json -PathType Leaf) {
        $j = $null
        try { $j = [IO.File]::ReadAllText($json) | ConvertFrom-Json } catch { }
        $base = $null
        if ($j -and $j.PSObject.Properties['baseName'] -and $j.baseName) { $base = [string]$j.baseName }
        elseif ($j -and $j.source -and $j.mode -eq 'remotion') { $base = ([string]$j.source) -replace '\s\(.*\)$', '' }
        elseif ($j -and $j.source) { $base = [IO.Path]::GetFileNameWithoutExtension([string]$j.source) }
        if ($base) { $names += "$base-review.pdf", "$base-changes.pdf" }
    }
    return $names
}

function Move-ReviewFiles([string]$from, [string]$to) {
    # Moves the review in $from to $to (or deletes it when $to is empty): only the files it wrote
    # and the frame images in its frames folder. Folders left empty are removed.
    $names = @(Get-ReviewFileNames $from)
    if ($to) { New-Item -ItemType Directory -Force -Path $to | Out-Null }
    foreach ($name in $names) {
        $p = Join-Path $from $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        if ($to) { Move-Item -LiteralPath $p -Destination (Join-Path $to $name) -Force } else { Remove-Item -LiteralPath $p -Force }
    }
    $frames = Join-Path $from 'frames'
    if (Test-Path -LiteralPath $frames -PathType Container) {
        $own = @(Get-ChildItem -LiteralPath $frames -File | Where-Object { $_.Name -match $script:FrameNamePattern })
        if ($to) {
            $dest = Join-Path $to 'frames'
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            $own | Move-Item -Destination $dest -Force
        } else {
            $own | Remove-Item -Force
        }
        if (-not (Get-ChildItem -LiteralPath $frames -Force)) { Remove-Item -LiteralPath $frames -Force }
    }
}

function Move-PreviousReview([string]$outDir) {
    # Keeps the last run in <OutDir>\previous so the next run can compare with it. The run kept
    # there before is deleted first. Only files the tool wrote are moved or deleted, so other files
    # in a folder given with -OutDir, or put in previous\, are left alone.
    $prev = Join-Path $outDir 'previous'
    if (Test-Path -LiteralPath $prev -PathType Container) { Move-ReviewFiles $prev '' }
    Move-ReviewFiles $outDir $prev
    return $prev
}

function Read-PreviousReview([string]$dir) {
    $json = Join-Path $dir 'review.json'
    if (-not (Test-Path -LiteralPath $json)) { throw "No review.json in $dir, so it can't be compared (it may be from an older version of this tool)." }
    $j = [IO.File]::ReadAllText($json) | ConvertFrom-Json
    $frames = @()
    foreach ($f in @($j.frames)) {
        $frames += [pscustomobject]@{ Index = [int]$f.index; Time = [double]$f.time; Name = $f.name; Lines = @($f.lines)
            Sig = $(if ($f.sig) { [Convert]::FromBase64String($f.sig) } else { $null }) }
    }
    return [pscustomobject]@{ Dir = $dir; Made = $j.made; Source = $j.source; SigW = [int]$j.sigW; SigH = [int]$j.sigH; Frames = $frames }
}

function Compare-WithPrevious($frames, $prev, [int]$sw, [int]$sh, [string]$outDir) {
    # A frame is unchanged when some previous frame looks the same: fewer than 0.2% of the
    # signature's pixels differ by more than 20 grey levels. Matching against every previous frame,
    # not just the one at the same time, keeps frames that only moved in time out of the list.
    $fa = @($frames)
    $res = [pscustomobject]@{ Prev = $prev; Changed = @(); Removed = @(); Note = ''; Total = $fa.Count; PrevLink = '' }
    $old = @($prev.Frames | Where-Object { $_.Sig })
    if ($prev.SigW -ne $sw -or $prev.SigH -ne $sh -or -not $old.Count) {
        $res.Note = 'The previous review has a different frame size or orientation, so every frame counts as changed.'
        foreach ($f in $fa) { $f.Change = [pscustomobject]@{ Prev = $null; PrevLink = ''; Added = @(Get-DiffWords (@($f.Lines | ForEach-Object { $_.Text }) -join ' ')); Removed = @() } }
        $res.Changed = $fa
        return $res
    }
    Initialize-AudioScan
    $limit = [Math]::Max(4, [int]($sw * $sh * 0.002))
    $newSigs = [byte[][]]@($fa | ForEach-Object { , $_.Sig })
    $oldSigs = [byte[][]]@($old | ForEach-Object { , $_.Sig })
    $fwd = [VideoReview.FrameDiff]::Closest($newSigs, $oldSigs, 20)
    $back = [VideoReview.FrameDiff]::Closest($oldSigs, $newSigs, 20)
    $relPrev = if ($prev.Dir.StartsWith($outDir, [StringComparison]::OrdinalIgnoreCase)) { $prev.Dir.Substring($outDir.Length).TrimStart('\').Replace('\', '/') } else { $prev.Dir.Replace('\', '/') }
    $changed = @()
    for ($i = 0; $i -lt $fa.Count; $i++) {
        $m = $fwd[$i]
        if ($m.Changed -le $limit) { continue }
        # Compare text with the previous frame nearest in time (the closest picture can be a
        # different slide when a whole slide is new).
        $near = $old | Sort-Object { [Math]::Abs($_.Time - $fa[$i].Time) } | Select-Object -First 1
        $diff = Compare-Words (@($near.Lines) -join ' ') (@($fa[$i].Lines | ForEach-Object { $_.Text }) -join ' ')
        $added = $diff.Added; $removed = $diff.Removed
        $fa[$i].Change = [pscustomobject]@{ Prev = $near; PrevLink = "$relPrev/frames/$($near.Name)"; Pixels = $m.Changed; Added = $added; Removed = $removed }
        $changed += $fa[$i]
    }
    $removedFrames = @()
    for ($j = 0; $j -lt $old.Count; $j++) { if ($back[$j].Changed -gt $limit) { $removedFrames += $old[$j] } }
    $res.Changed = $changed
    $res.Removed = $removedFrames
    $res.PrevLink = $relPrev
    return $res
}

function Get-DiffWords([string]$text) {
    # Words for comparing two readings of a frame. Fragments of one or two letters are mostly OCR
    # noise that varies between renders ("C)" for a folder icon), so only numbers keep them.
    return @([regex]::Matches($text.ToLowerInvariant(), '[\p{L}\p{Nd}]+(?:[.,]\d+)*') | ForEach-Object { $_.Value } |
            Where-Object { $_ -match '\d' -or $_.Length -ge 3 })
}

function Compare-Words([string]$old, [string]$new) {
    # Words added and removed, each kept once, in the order they appear on screen.
    $count = @{}
    foreach ($w in (Get-DiffWords $old)) { $count[$w] = 1 + [int]$count[$w] }
    $added = @()
    foreach ($w in (Get-DiffWords $new)) { if ([int]$count[$w] -gt 0) { $count[$w]-- } elseif ($added -notcontains $w) { $added += $w } }
    $removed = @()
    foreach ($w in (Get-DiffWords $old)) { if ([int]$count[$w] -gt 0 -and $removed -notcontains $w) { $removed += $w } }
    return [pscustomobject]@{ Added = $added; Removed = $removed }
}

function Write-ReviewJson([string]$file, $ctx, $frames, [int]$sw, [int]$sh) {
    $list = @()
    foreach ($f in $frames) {
        $list += [ordered]@{ index = $f.Index; time = [Math]::Round($f.Time, 3); frame = $f.Frame; name = $f.Name; why = $f.Why
            lines = @($f.Lines | ForEach-Object { $_.Text }); flags = @($f.Flags | Select-Object -Unique); sig = $(if ($f.Sig) { [Convert]::ToBase64String($f.Sig) } else { $null }) }
    }
    $doc = [ordered]@{ tool = 'video-review'; version = 2; made = (Get-Date -Format 'yyyy-MM-dd HH:mm'); source = $ctx.Title
        baseName = $ctx.BaseName; mode = $ctx.Mode; width = $ctx.Width; height = $ctx.Height; duration = [Math]::Round($ctx.Duration, 3); sigW = $sw; sigH = $sh; frames = $list }
    Write-Utf8 $file (ConvertTo-Json -InputObject $doc -Depth 5 -Compress)
}

# ---------------------------------------------------------------------------------------------
# Report sections (Markdown and HTML)
# ---------------------------------------------------------------------------------------------

function Get-FrameRef($idxs, [int]$max = 6) {
    $a = @($idxs)
    $s = (($a | Select-Object -First $max | ForEach-Object { "#$_" }) -join ', ')
    if ($a.Count -gt $max) { $s += " and $($a.Count - $max) more" }
    return $s
}

function Get-WordList($words, [int]$max = 25) {
    $a = @($words)
    $s = ($a | Select-Object -First $max) -join ' '
    if ($a.Count -gt $max) { $s += " (+$($a.Count - $max) more)" }
    return $s
}

function Build-ChangesMarkdown($chg, $nl) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("## Changes since the last review (changes only)$nl$nl")
    [void]$sb.Append("Compared with the review made $($chg.Prev.Made) of $($chg.Prev.Source) (``$($chg.PrevLink)``). ")
    if ($chg.Note) { [void]$sb.Append("$($chg.Note) ") }
    [void]$sb.Append(("{0} of {1} frames changed; {2} previous frame(s) no longer appear.{3}{3}" -f @($chg.Changed).Count, $chg.Total, @($chg.Removed).Count, $nl))
    if (@($chg.Changed).Count) {
        [void]$sb.Append("| # | Time | Frame | Before (nearest in time) | Words added | Words removed |$nl|---|---|---|---|---|---|$nl")
        foreach ($f in $chg.Changed) {
            $before = if ($f.Change.Prev) { "[$(Format-Time $f.Change.Prev.Time)]($($f.Change.PrevLink))" } else { '' }
            [void]$sb.Append("| $($f.Index) | $(Format-Time $f.Time) | [$($f.Name)](frames/$($f.Name)) | $before | $(Get-Md (Get-WordList $f.Change.Added)) | $(Get-Md (Get-WordList $f.Change.Removed)) |$nl")
        }
        [void]$sb.Append("${nl}A frame counts as changed when no frame of the previous review looks the same. The word columns compare its OCR text with the previous frame nearest in time (fragments under 3 letters are ignored, numbers always count); empty columns mean the change is in the picture only, or in text OCR did not read.$nl")
    }
    if (@($chg.Removed).Count) {
        [void]$sb.Append("${nl}Previous frames with no match now: " + ((@($chg.Removed) | Select-Object -First 20 | ForEach-Object { "[$(Format-Time $_.Time)]($($chg.PrevLink)/frames/$($_.Name))" }) -join ', ') + "$nl")
    }
    [void]$sb.Append($nl)
    return $sb.ToString()
}

function Build-ChecksMarkdown($checks, $nl) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("## On-screen text checks$nl$nl")
    if (-not $checks) { [void]$sb.Append("Skipped (-NoOcr).$nl$nl"); return $sb.ToString() }
    [void]$sb.Append("Text read from every frame with Windows' built-in OCR. OCR can misread small or stylised text (an I read as 1, an l as I), so treat these as things to look at.$nl$nl")

    [void]$sb.Append("### Possible spelling mistakes$nl$nl")
    $sp = $checks.Spelling
    if (@($sp.Words).Count) {
        [void]$sb.Append("| Word | Suggestions | Frames | In |$nl|---|---|---|---|$nl")
        foreach ($w in $sp.Words) { [void]$sb.Append("| $(Get-Md $w.Word) | $(Get-Md ($w.Suggestions -join ', ')) | $(Get-FrameRef $w.Frames) | $(Get-Md $w.Line) |$nl") }
    } else { [void]$sb.Append("None among $($sp.Checked) distinct words checked.$nl") }
    if (@($sp.ReadOnce).Count) {
        [void]$sb.Append("${nl}Probably OCR misreads (rejected by the spell checker, but read that way in only the original or only the inverted copy): " + (Get-Md ((@($sp.ReadOnce) | Select-Object -First 40) -join ', ')) + ".$nl")
    }
    if (@($sp.Typing).Count) {
        [void]$sb.Append("${nl}Skipped as text being typed on (the start of a longer word seen in another frame): " + (Get-Md ((@($sp.Typing) | Select-Object -First 20) -join ', ')) + ".$nl")
    }
    [void]$sb.Append("${nl}A word is listed only when the original frame and an inverted copy both read it the same way. Not checked: words under 4 letters, words with digits, short all-caps words and camelCase names, words in the narration")
    if (@($sp.AllowFiles).Count) { [void]$sb.Append(', and words in ' + ((@($sp.AllowFiles) | ForEach-Object { '`' + [IO.Path]::GetFileName($_) + '`' }) -join ', ')) }
    [void]$sb.Append(". Add accepted words to ``review-words.txt`` in the project folder.$nl$nl")

    [void]$sb.Append("### Reading time$nl$nl")
    if ($null -eq $checks.Reading) { [void]$sb.Append("Only for video files (it needs the scene changes).$nl$nl") }
    else {
        $flagged = @($checks.Reading | Where-Object { $_.Worst })
        [void]$sb.Append(("At {0} words a second. Slides run between scene changes; text carried over from the previous slide is not counted. {1} of {2} slide(s) are too quick.{3}{3}" -f $WordsPerSecond, $flagged.Count, @($checks.Reading).Count, $nl))
        [void]$sb.Append("| Slide | Shown | New words | Needs | Too quick? | Frames | Starts with |$nl|---|---|---|---|---|---|---|$nl")
        foreach ($s in $checks.Reading) {
            $q = if ($s.Worst) { ('**yes**: {0} words from {1} need {2:0.0} s, {3:0.0} s left' -f $s.Worst.Words, (Format-Time $s.Worst.From), $s.Worst.Need, $s.Worst.Avail) } else { 'no' }
            [void]$sb.Append(('| {0} | {1} to {2} ({3:0.0} s) | {4} | {5:0.0} s | {6} | {7} | {8} |{9}' -f $s.Index, (Format-Time $s.Start), (Format-Time $s.End), ($s.End - $s.Start), $s.Words, ($s.Words / $WordsPerSecond), $q, (Get-FrameRef $s.Frames 3), (Get-Md $s.Sample), $nl))
        }
        [void]$sb.Append($nl)
    }

    [void]$sb.Append("### Numbers in the narration$nl$nl")
    if ($null -eq $checks.Numbers) { [void]$sb.Append("Needs narration placed in time.$nl$nl") }
    else {
        $bad = @($checks.Numbers | Where-Object { $_.Missing.Count })
        [void]$sb.Append(("Numbers spoken in a line (digits, and number words from {0} up) checked against the text on screen from 0.5 s before the line to 1 s after it. {1} of {2} line(s) with numbers have one missing.{3}{3}" -f $NumberWordsFrom, $bad.Count, @($checks.Numbers).Count, $nl))
        if (@($checks.Numbers).Count) {
            [void]$sb.Append("| Line | Time | Says | Missing on screen | On screen then | Frames |$nl|---|---|---|---|---|---|$nl")
            foreach ($r in $checks.Numbers) {
                $miss = if ($r.Missing.Count) { '**' + (($r.Missing | ForEach-Object { $_.Text }) -join ', ') + '**' } else { 'none' }
                [void]$sb.Append("| $($r.Line) | $(Format-Time $r.Start) | $(Get-Md (($r.Spoken | ForEach-Object { $_.Text }) -join ', ')) | $miss | $(Get-Md ((@($r.Screen) | Select-Object -First 15) -join ', ')) | $(Get-FrameRef $r.Frames 4) |$nl")
            }
        }
        [void]$sb.Append($nl)
    }

    [void]$sb.Append("### Shorts safe areas$nl$nl")
    if ($null -eq $checks.Safe) { [void]$sb.Append("Not a vertical 9:16 video, so not checked.$nl$nl") }
    else {
        $m = $checks.Safe.Margins
        [void]$sb.Append(("Margins (at 1080x1920): top {0}, right {1}, bottom {2}, left {3} px, from Google's Universal Video Ad Safe Zones for vertical video, the most cautious published guide. Change them with -SafeMargins. {4} piece(s) of text fall in them.{5}{5}" -f $m[0], $m[1], $m[2], $m[3], @($checks.Safe.Hits).Count, $nl))
        if (@($checks.Safe.Hits).Count) {
            [void]$sb.Append("| Text | Margin | Shown | Frames |$nl|---|---|---|---|$nl")
            foreach ($h in $checks.Safe.Hits) { [void]$sb.Append("| $(Get-Md $h.Text) | $($h.Edges -join ', ') | $(Format-Time $h.First) to $(Format-Time $h.Last) | $(Get-FrameRef $h.Frames 4) |$nl") }
            [void]$sb.Append($nl)
        }
    }
    return $sb.ToString()
}

function Build-ChecksHtml($checks) {
    if (-not $checks) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<h2>On-screen text checks</h2>')
    $sp = @($checks.Spelling.Words)
    [void]$sb.Append("<p><b>Possible spelling mistakes</b>: ")
    if ($sp.Count) {
        [void]$sb.Append('</p><table><tr><th>Word</th><th>Suggestions</th><th>Frames</th></tr>')
        foreach ($w in ($sp | Select-Object -First 20)) { [void]$sb.Append("<tr><td class='bad'>$(Get-Html $w.Word)</td><td>$(Get-Html ($w.Suggestions -join ', '))</td><td>$(Get-Html (Get-FrameRef $w.Frames 4))</td></tr>") }
        [void]$sb.Append('</table>')
    } else { [void]$sb.Append('none.</p>') }
    if ($null -ne $checks.Reading) {
        $fl = @($checks.Reading | Where-Object { $_.Worst })
        [void]$sb.Append("<p><b>Too quick to read</b> (at $WordsPerSecond words a second): ")
        if ($fl.Count) {
            [void]$sb.Append('</p><table><tr><th>Slide</th><th>Shown</th><th>Needs</th><th>Starts with</th></tr>')
            foreach ($s in $fl) { [void]$sb.Append(('<tr><td>{0}</td><td>{1} ({2:0.0} s left for {3} words)</td><td>{4:0.0} s</td><td>{5}</td></tr>' -f $s.Index, (Format-Time $s.Worst.From), $s.Worst.Avail, $s.Worst.Words, $s.Worst.Need, (Get-Html $s.Sample))) }
            [void]$sb.Append('</table>')
        } else { [void]$sb.Append('none.</p>') }
    }
    if ($null -ne $checks.Numbers) {
        $bad = @($checks.Numbers | Where-Object { $_.Missing.Count })
        [void]$sb.Append('<p><b>Spoken numbers not on screen</b>: ')
        if ($bad.Count) {
            [void]$sb.Append('</p><table><tr><th>Time</th><th>Missing</th><th>On screen then</th><th>Line</th></tr>')
            foreach ($r in $bad) { [void]$sb.Append("<tr><td>$(Format-Time $r.Start)</td><td class='bad'>$(Get-Html (($r.Missing | ForEach-Object { $_.Text }) -join ', '))</td><td>$(Get-Html ((@($r.Screen) | Select-Object -First 10) -join ', '))</td><td>$(Get-Html $r.Text)</td></tr>") }
            [void]$sb.Append('</table>')
        } else { [void]$sb.Append("none ($(@($checks.Numbers).Count) line(s) with numbers checked).</p>") }
    }
    if ($null -ne $checks.Safe) {
        $m = $checks.Safe.Margins
        [void]$sb.Append(("<p><b>Shorts safe areas</b> (top {0}, right {1}, bottom {2}, left {3} px at 1080x1920; Google's vertical video ad safe zone): " -f $m[0], $m[1], $m[2], $m[3]))
        if (@($checks.Safe.Hits).Count) {
            [void]$sb.Append('</p><table><tr><th>Text</th><th>Margin</th><th>Shown</th></tr>')
            foreach ($h in ($checks.Safe.Hits | Select-Object -First 15)) { [void]$sb.Append("<tr><td>$(Get-Html $h.Text)</td><td>$($h.Edges -join ', ')</td><td>$(Format-Time $h.First) to $(Format-Time $h.Last)</td></tr>") }
            [void]$sb.Append('</table>')
        } else { [void]$sb.Append('no text in them.</p>') }
    }
    return $sb.ToString()
}

function Build-ChangesHtml($chg) {
    if (-not $chg) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<h2>Changes since the last review</h2><p>Compared with the review made $(Get-Html $chg.Prev.Made). $(Get-Html $chg.Note) ")
    [void]$sb.Append(("{0} of {1} frames changed; {2} previous frame(s) no longer appear.</p>" -f @($chg.Changed).Count, $chg.Total, @($chg.Removed).Count))
    if (@($chg.Changed).Count) {
        [void]$sb.Append('<table><tr><th>#</th><th>Time</th><th>Words added</th><th>Words removed</th></tr>')
        foreach ($f in ($chg.Changed | Select-Object -First 30)) { [void]$sb.Append("<tr><td>$($f.Index)</td><td>$(Format-Time $f.Time)</td><td>$(Get-Html (Get-WordList $f.Change.Added))</td><td>$(Get-Html (Get-WordList $f.Change.Removed))</td></tr>") }
        [void]$sb.Append('</table>')
    }
    return $sb.ToString()
}
