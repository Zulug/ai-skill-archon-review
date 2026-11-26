[CmdletBinding(DefaultParameterSetName = 'Implement')]
param(
    [string]$Workspace = (Get-Location).Path,
    [Parameter(Mandatory, ParameterSetName = 'Implement')]
    [Parameter(ParameterSetName = 'Review')]
    [string]$Feature,
    [Parameter(Mandatory, ParameterSetName = 'Review')][switch]$ReviewPending,
    # Git only: also review commits since the branch split from this revision, such as main.
    [string]$Base
)

$ErrorActionPreference = 'Stop'
$root = (Get-Item -LiteralPath $Workspace).FullName

# Windows PowerShell turns native stderr into errors under 'Stop', so probe git leniently.
function Invoke-Git([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & git -C $root @Arguments 2>$null
    if ($LASTEXITCODE -eq 0) { ($output | Select-Object -First 1) }
}

# Check Plastic first: a Plastic workspace can also contain an empty .git folder.
if (Test-Path -LiteralPath (Join-Path $root '.plastic') -PathType Container) {
    if ($Base) { throw 'Use -Base only in a git repository.' }
    $vcsGuide = 'This is a Plastic SCM workspace; review its pending changes. List them with ' +
        'cm status --all --xml. Use cm cat to read base revisions and compare them with the current files ' +
        'in memory. Do not use cm diff with a workspace file path, because it opens a graphical diff.'
} else {
    $topLevel = Invoke-Git @('rev-parse', '--show-toplevel')
    if (-not $topLevel -or [IO.Path]::GetFullPath($topLevel).TrimEnd('\') -ine $root.TrimEnd('\')) {
        throw 'Use the root of a Plastic workspace or a git repository.'
    }
    if ($Base) {
        if ($Base.StartsWith('-')) { throw "Use a revision name for -Base. Base=$Base" }
        $mergeBase = Invoke-Git @('merge-base', 'HEAD', $Base)
        if (-not $mergeBase) { throw "The base revision has no merge base with HEAD. Base=$Base" }
        $vcsGuide = "This is a git repository; review every change since its merge base $mergeBase with $Base, " +
            "committed and uncommitted. git --no-pager diff $mergeBase shows tracked changes against it, " +
            "git --no-pager log $mergeBase..HEAD lists the commits, and git status --porcelain -uall shows " +
            "untracked files. Use git show ${mergeBase}:<path> for base versions."
    } else {
        $vcsGuide = 'This is a git repository; review its uncommitted changes. git status --porcelain -uall ' +
            'lists them, including untracked files, and git --no-pager diff HEAD shows the tracked changes. ' +
            'Use git show HEAD:<path> for base versions.'
    }
    # Claude Code's code-review skill works from git, so Plastic keeps the plain review.
    $claudeReviewMethod = 'Run the code-review skill at level high on exactly these changes, choosing its ' +
        'target to match them. Do not pass --fix or --comment. Use its findings as your review: verify each ' +
        'one, drop any you can show to be false, and add only missed issues you can support with evidence.'
}

$archonCommand = Get-Command archon.exe -ErrorAction SilentlyContinue
$archon = if ($archonCommand) { $archonCommand.Source } else { Join-Path $env:USERPROFILE '.archon\bin\archon.exe' }
if (-not (Test-Path -LiteralPath $archon -PathType Leaf)) { throw 'Archon is not installed.' }

if ([string]::IsNullOrWhiteSpace($Feature)) {
    if (-not $ReviewPending) { throw 'Supply a feature description.' }
    $Feature = if ($Base) { "Review the changes since $Base for actionable issues." }
        else { 'Review the existing uncommitted changes for actionable issues.' }
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
    $inputs = @('--input', "feature=$Feature", '--input', "mode=$mode", '--input', "vcs_guide=$vcsGuide",
        '--input', "cross_check_runner=$crossCheckRunner")
    if ($claudeReviewMethod) { $inputs += @('--input', "claude_review_method=$claudeReviewMethod") }
    & $archon workflow run feature-review --folder --cwd $root --config $settings `
        --workflow-source $PSScriptRoot @inputs
    if ($LASTEXITCODE -ne 0) { throw 'The Archon workflow failed. Inspect the run before continuing.' }
} finally {
    $env:CODEX_BIN_PATH = $priorCodex
    $env:PATH = $priorPath
}
