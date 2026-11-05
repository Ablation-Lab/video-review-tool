<#
  Tests that review-video.ps1 runs a Remotion project's own CLI with Node directly, never through
  npx, so nothing is downloaded. Uses a fake @remotion/cli package in a temp folder; no network.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Remotion-Cli.Tests.ps1
  Exit code 0 means every check passed. Needs Node.js (the check is skipped without it).
#>
$ErrorActionPreference = 'Stop'
$script:Failed = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" } else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:Failed++ }
}
function Put([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $text)
}

$scriptPath = Join-Path $PSScriptRoot '..\skills\video-review-skill\review-video.ps1'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host 'Node.js not found: skipped.'; exit 0 }

# Load only the functions this test needs from review-video.ps1 (the script itself runs a review).
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath), [ref]$null, [ref]$null)
$want = 'ConvertTo-Arg', 'Invoke-Tool', 'Get-ToolPath', 'Get-RemotionCli', 'Invoke-Remotion', 'Initialize-Remotion'
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($want -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
function Write-Step([string]$s) { }
$Composition = $null

$root = Join-Path ([IO.Path]::GetTempPath()) ('video-review-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    # A project folder with spaces in its name, and a fake Remotion CLI that logs its arguments.
    $project = Join-Path $root 'my project'
    $log = Join-Path $root 'args.log'
    Put (Join-Path $project 'package.json') '{"name":"demo","dependencies":{"remotion":"4.0.0","@remotion/cli":"4.0.0"}}'
    Put (Join-Path $project 'node_modules\@remotion\cli\package.json') '{"name":"@remotion/cli","version":"4.0.0","bin":{"remotion":"remotion-cli.js"}}'
    Put (Join-Path $project 'node_modules\@remotion\cli\remotion-cli.js') @"
const fs = require('fs');
fs.appendFileSync(process.env.FAKE_LOG, process.argv.slice(2).join('|') + '\n');
if (process.argv[2] === 'compositions') console.log('Main      30      1080x1920      90 (3.00 sec)');
"@
    $env:FAKE_LOG = $log

    Write-Host 'The project has its own Remotion CLI'
    $rem = Initialize-Remotion $project (Join-Path $root 'work')
    Check ($script:RemotionCli -like '*\node_modules\@remotion\cli\remotion-cli.js') 'finds the CLI script from the package''s bin field'
    Check ([IO.Path]::GetFileName($script:Node) -ieq 'node.exe') 'runs it with node.exe, not npx'
    $calls = @(Get-Content -LiteralPath $log)
    $bundle = Join-Path $root 'work\bundle'
    Check ($calls.Count -eq 2) 'ran the CLI twice (bundle, compositions)'
    Check ($calls[0] -eq "bundle|--out-dir|$bundle|--log=error") 'bundle got its arguments intact'
    Check ($calls[1] -eq "compositions|$bundle") 'compositions got its arguments intact'
    Check ($rem.Comp.Id -eq 'Main' -and $rem.Comp.Width -eq 1080 -and $rem.Comp.Frames -eq 90) 'reads the composition list'

    $png = Join-Path $root 'out dir\r000030.png'
    $null = Invoke-Remotion @('still', $rem.Bundle, 'Main', $png, '--frame=30') 'remotion still' $project
    $last = Get-Content -LiteralPath $log | Select-Object -Last 1
    Check ($last -eq ('still|' + $rem.Bundle + '|Main|' + $png + '|--frame=30')) 'paths with spaces reach the CLI as single arguments'

    Write-Host 'Projects where the CLI is missing or broken'
    $bare = Join-Path $root 'bare'
    Put (Join-Path $bare 'package.json') '{"dependencies":{"remotion":"4.0.0"}}'
    $err = $null; try { Initialize-Remotion $bare $root } catch { $err = $_.Exception.Message }
    Check ($err -match "Remotion's CLI is not installed") 'no node_modules: refuses before running anything'
    $evil = Join-Path $root 'evil'
    Put (Join-Path $evil 'package.json') '{"dependencies":{"remotion":"4.0.0"}}'
    Put (Join-Path $evil 'node_modules\@remotion\cli\package.json') '{"bin":{"remotion":"..\\..\\..\\outside.js"}}'
    Put (Join-Path $evil 'outside.js') 'process.exit(0)'
    $err = $null; try { Initialize-Remotion $evil $root } catch { $err = $_.Exception.Message }
    Check ($err -match 'incomplete') 'a bin path outside the package folder is refused'
    $nobin = Join-Path $root 'nobin'
    Put (Join-Path $nobin 'package.json') '{"dependencies":{"remotion":"4.0.0"}}'
    Put (Join-Path $nobin 'node_modules\@remotion\cli\package.json') '{"name":"@remotion/cli"}'
    $err = $null; try { Initialize-Remotion $nobin $root } catch { $err = $_.Exception.Message }
    Check ($err -match "doesn't name its remotion command") 'a package without a bin field is refused'
} finally {
    Remove-Item Env:\FAKE_LOG -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed) { Write-Host "$script:Failed check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
