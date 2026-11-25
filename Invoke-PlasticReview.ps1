[CmdletBinding(DefaultParameterSetName = 'Implement')]
param(
    [string]$Workspace = (Get-Location).Path,
    [Parameter(Mandatory, ParameterSetName = 'Implement')]
    [Parameter(ParameterSetName = 'Review')]
    [string]$Feature,
    [Parameter(Mandatory, ParameterSetName = 'Review')][switch]$ReviewPending
)

$ErrorActionPreference = 'Stop'
$root = (Get-Item -LiteralPath $Workspace).FullName
if (-not (Test-Path -LiteralPath (Join-Path $root '.plastic') -PathType Container)) {
    throw 'Use the root of a local Plastic workspace.'
}

$archonCommand = Get-Command archon.exe -ErrorAction SilentlyContinue
$archon = if ($archonCommand) { $archonCommand.Source } else { Join-Path $env:USERPROFILE '.archon\bin\archon.exe' }
if (-not (Test-Path -LiteralPath $archon -PathType Leaf)) { throw 'Archon is not installed.' }

if ([string]::IsNullOrWhiteSpace($Feature)) {
    if (-not $ReviewPending) { throw 'Supply a feature description.' }
    $Feature = 'Review the existing pending Plastic changes for actionable issues.'
}
$mode = if ($ReviewPending) { 'review' } else { 'implement' }
$settings = Join-Path $PSScriptRoot 'models.yaml'
$crossCheckRunner = Join-Path $PSScriptRoot 'scripts\Resume-ArchonReviewer.ps1'

$priorCodex = $env:CODEX_BIN_PATH
$priorPath = $env:PATH
try {
    if (-not $priorCodex) {
        $codex = Get-Command codex.exe -ErrorAction SilentlyContinue
        if ($codex) { $env:CODEX_BIN_PATH = $codex.Source }
        elseif (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
            $app = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue
            if ($app) { $env:CODEX_BIN_PATH = Join-Path $app.InstallLocation 'app\resources\codex.exe' }
        }
    }
    # Archon runs bash nodes with Git Bash.
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $gitBin = Join-Path (Split-Path (Split-Path $git)) 'bin'
    if (Test-Path -LiteralPath (Join-Path $gitBin 'bash.exe')) { $env:PATH = "$gitBin;$priorPath" }

    # The workflow definition stays in the skill, so the workspace gets no .archon folder.
    & $archon workflow run plastic-feature-review --folder --cwd $root --config $settings `
        --workflow-source $PSScriptRoot --input "feature=$Feature" --input "mode=$mode" `
        --input "cross_check_runner=$crossCheckRunner"
    if ($LASTEXITCODE -ne 0) { throw 'The Archon workflow failed. Inspect the run before continuing.' }
} finally {
    $env:CODEX_BIN_PATH = $priorCodex
    $env:PATH = $priorPath
}
