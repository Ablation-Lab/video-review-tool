<#
  Helper for review-video.ps1: Windows' built-in OCR and spell checker. No installs needed.
  Runs in Windows PowerShell 5.1 (powershell.exe), which can call the Windows Runtime OCR API;
  review-video.ps1 starts it that way even when it runs in PowerShell 7.

    windows-text.ps1 -Mode ocr   -In <list of image paths, one per line> -Out <json>
    windows-text.ps1 -Mode spell -In <list of words, one per line>       -Out <json>

  ocr:   [ { "path": "...", "lines": [ { "text": "...", "words": [ { "text", "x", "y", "w", "h" } ] } ] } ]
  spell: { "<misspelt word>": [ "suggestion", ... ] }   (only the words the checker rejects)
  Exit codes: 0 done, 2 failed (the reason is on stderr).
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('ocr', 'spell')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$In,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Language
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

function Fail([string]$msg) { [Console]::Error.WriteLine($msg); exit 2 }

try {
    $items = @([IO.File]::ReadAllLines($In, $utf8) | Where-Object { $_.Trim() })

    if ($Mode -eq 'ocr') {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
            Select-Object -First 1
        function Await($op, [type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); [void]$task.Wait(-1); return $task.Result }

        if ($Language) {
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language $Language))
        } else { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
        if (-not $engine) {
            $have = (@([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) | ForEach-Object { $_.LanguageTag }) -join ', '
            Fail ("Windows OCR has no recognizer for {0}. Installed: {1}. Add one in Settings > Time & language > Language & region (add the language with its optional features), or run -NoOcr." -f $(if ($Language) { $Language } else { 'your profile languages' }), $(if ($have) { $have } else { 'none' }))
        }
        $max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
        $results = New-Object System.Collections.Generic.List[object]
        foreach ($path in $items) {
            $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
            $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            try {
                $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
                if ($decoder.PixelWidth -gt $max -or $decoder.PixelHeight -gt $max) { Fail "$path is larger than Windows OCR's limit of $max pixels." }
                $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
                $r = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            } finally { $stream.Dispose() }
            $lines = @()
            foreach ($l in @($r.Lines)) {
                $words = @()
                foreach ($w in @($l.Words)) {
                    $b = $w.BoundingRect
                    $words += [ordered]@{ text = $w.Text; x = [int]$b.X; y = [int]$b.Y; w = [int]$b.Width; h = [int]$b.Height }
                }
                $lines += [ordered]@{ text = $l.Text; words = $words }
            }
            $results.Add([ordered]@{ path = $path; lines = $lines })
        }
        $json = ConvertTo-Json -InputObject $results.ToArray() -Depth 6 -Compress
    } else {
        Add-Type -AssemblyName PresentationFramework
        $tb = New-Object System.Windows.Controls.TextBox
        $lang = if ($Language) { $Language } else { (Get-Culture).Name }
        $tb.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage($lang)
        [System.Windows.Controls.SpellCheck]::SetIsEnabled($tb, $true)
        $bad = [ordered]@{}
        foreach ($word in $items) {
            $tb.Text = $word
            $i = $tb.GetNextSpellingErrorCharacterIndex(0, [System.Windows.Documents.LogicalDirection]::Forward)
            if ($i -ge 0) {
                $err = $tb.GetSpellingError($i)
                $bad[$word] = @(@($err.Suggestions) | Select-Object -First 3)
            }
        }
        $json = ConvertTo-Json -InputObject $bad -Depth 3 -Compress
        if (-not $bad.Count) { $json = '{}' }
    }
    [IO.File]::WriteAllText($Out, $json, $utf8)
    exit 0
}
catch { Fail ("windows-text.ps1 ($Mode) failed: " + $_.Exception.Message) }
