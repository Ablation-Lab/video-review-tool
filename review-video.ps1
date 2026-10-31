# Shortcut so .\review-video.ps1 works from the repository root. The tool itself lives in
# skills\video-review\, so that folder can be installed on its own as a Claude Code skill.
# Help and options: Get-Help .\skills\video-review\review-video.ps1 -Full
& (Join-Path $PSScriptRoot 'skills\video-review\review-video.ps1') @args
exit $LASTEXITCODE
