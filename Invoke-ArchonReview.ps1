# Windows PowerShell strips quotes from native command arguments, which would corrupt the
# feature, corrections, and implementer session inputs passed to Archon.
#Requires -Version 7.3
[CmdletBinding(DefaultParameterSetName = 'Implement')]
param(
    [string]$Workspace = (Get-Location).Path,
    # In continue mode, the original request the reviewers check the changes against.
    [Parameter(Mandatory, ParameterSetName = 'Implement')]
    [Parameter(ParameterSetName = 'Review')]
    [Parameter(Mandatory, ParameterSetName = 'Continue')]
    [string]$Feature,
    [Parameter(Mandatory, ParameterSetName = 'Review')][switch]$ReviewPending,
    # The transcript of an earlier run in this workspace whose implementer session applies the
    # corrections before the review: the run that implemented, or a later continue run.
    [Parameter(Mandatory, ParameterSetName = 'Continue')][string]$ContinueFrom,
    [Parameter(Mandatory, ParameterSetName = 'Continue')][string]$Corrections,
    # Git only: also review commits since the branch split from this revision, such as main.
    [string]$Base
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\ArchonSession.ps1')
$root = (Get-Item -LiteralPath $Workspace).FullName

# Windows PowerShell turns native stderr into errors under 'Stop', so probe git leniently.
function Invoke-Git([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & git -C $root @Arguments 2>$null
    if ($LASTEXITCODE -eq 0) { ($output | Select-Object -First 1) }
}

# The third reviewer uses the pr-review-board skill, which sits next to this skill.
$skillsRoot = Split-Path $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $skillsRoot 'pr-review-board\SKILL.md') -PathType Leaf)) {
    throw "The third reviewer needs the pr-review-board skill. SkillsFolder=$skillsRoot"
}
$boardReviewMethod = 'Use the pr-review-board skill for this review: follow its review passes, its ' +
    'reviewer rubric, and its evidence and severity reasoning as written. Its output section does not ' +
    'apply: return its findings in the JSON format below, not its markdown report. Set priorities with ' +
    'the scale below, not its BLOCKER, P1, P2, and NIT labels: a NIT that violates the project''s ' +
    'guidelines or instruction files is P1, and other NITs are P3. Report actionable performance risks ' +
    'and simplifications from its nonblocking comments as findings too. Do not use subagents, and do ' +
    'not publish review comments.'

# Check Plastic first: a Plastic workspace can also contain an empty .git folder.
if (Test-Path -LiteralPath (Join-Path $root '.plastic') -PathType Container) {
    if ($Base) { throw 'Use -Base only in a git repository.' }
    $vcsGuide = 'This is a Plastic SCM workspace; review its pending changes. List them with ' +
        'cm status --all --xml. Use cm cat to read base revisions and compare them with the current files ' +
        'in memory. Do not use cm diff with a workspace file path, because it opens a graphical diff.'
    # pr-review-board describes committed changes; its plastic-scm helper captures pending ones.
    $plasticHelper = Join-Path $skillsRoot 'plastic-scm\scripts\plastic.py'
    if (-not (Test-Path -LiteralPath $plasticHelper -PathType Leaf)) {
        throw "The third reviewer needs the plastic-scm skill's helper. Helper=$plasticHelper"
    }
    $boardReviewMethod += ' Its instructions describe committed changesets, branches, and shelvesets, ' +
        'but this review covers pending changes, which its sibling plastic-scm skill captures with its ' +
        "documented local-diff command: python '$plasticHelper' --cwd '$root' local-diff. That command " +
        'reads the pending changes without changing working files. Treat its manifest as the review ' +
        'target in place of a changeset capture: the local files are the reviewed revision, and the ' +
        'loaded revisions are the base. The capture files it writes under the system temporary ' +
        'directory, outside the workspace, are the only files you may create; nothing in the workspace ' +
        'may change.'
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
        'one, drop any you can show to be false, and add only missed issues you can support with evidence. ' +
        'Set priorities with the scale below, not its own labels: a nit that violates the project''s ' +
        'guidelines or instruction files is P1, and other nits are P3.'
    $boardReviewMethod += ' Its capture steps use Plastic SCM, which this repository does not use: ' +
        'capture the changes with the git commands above instead, and treat the working tree as the ' +
        'reviewed revision. The rest of the skill applies unchanged.'
}

$archon = Get-ArchonExecutable
if (-not (Test-Path -LiteralPath $archon -PathType Leaf)) { throw 'Archon is not installed.' }

if ([string]::IsNullOrWhiteSpace($Feature)) {
    if (-not $ReviewPending) { throw 'Supply a feature description.' }
    $Feature = if ($Base) { "Review the changes since $Base for actionable issues." }
        else { 'Review the existing uncommitted changes for actionable issues.' }
}
$mode = switch ($PSCmdlet.ParameterSetName) { 'Review' { 'review' } 'Continue' { 'continue' } default { 'implement' } }
$settings = Join-Path $PSScriptRoot 'models.yaml'
$crossCheckRunner = Join-Path $PSScriptRoot 'scripts\Resume-ArchonReviewer.ps1'

# The continuation resumes the session with the provider, model, and effort the earlier run
# recorded, so a models.yaml change after that run does not switch the implementer.
$implementerSession = $null
if ($mode -eq 'continue') {
    if ([string]::IsNullOrWhiteSpace($Corrections)) { throw 'Supply the corrections for the implementer.' }
    $source = & (Join-Path $PSScriptRoot 'scripts\Get-ArchonRunReport.ps1') -Transcript $ContinueFrom -Workspace $root |
        ConvertFrom-Json
    $sourceImplementer = $source.Implementer
    if (-not $source.Completed) { throw "The earlier run has not completed. RunId=$($source.RunId)" }
    if (-not $sourceImplementer.SessionId -or -not $sourceImplementer.Provider) {
        throw "The earlier run has no implementer session to continue. RunId=$($source.RunId), Note=$($sourceImplementer.Note)"
    }
    $implementerSession = ConvertTo-Json -Compress -Depth 6 -InputObject @{
        provider = $sourceImplementer.Provider
        model = $sourceImplementer.Model
        effort = $sourceImplementer.Effort
        session_id = $sourceImplementer.SessionId
        prior_tokens = $sourceImplementer.SessionUsage.Tokens
        prior_cost_usd = $sourceImplementer.SessionUsage.CostUsd
    }
}

$priorCodex = $env:CODEX_BIN_PATH
$priorPath = $env:PATH
try {
    if (-not $priorCodex) {
        $codex = Get-CodexExecutable
        if ($codex) { $env:CODEX_BIN_PATH = $codex }
    }
    # Archon runs bash nodes with Git Bash.
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $gitBin = Join-Path (Split-Path (Split-Path $git)) 'bin'
    if (Test-Path -LiteralPath (Join-Path $gitBin 'bash.exe')) { $env:PATH = "$gitBin;$priorPath" }

    # The workflow definition stays in the skill, so the workspace gets no .archon folder.
    $inputs = @('--input', "feature=$Feature", '--input', "mode=$mode", '--input', "vcs_guide=$vcsGuide",
        '--input', "cross_check_runner=$crossCheckRunner", '--input', "board_review_method=$boardReviewMethod")
    if ($claudeReviewMethod) { $inputs += @('--input', "claude_review_method=$claudeReviewMethod") }
    if ($implementerSession) {
        $inputs += @('--input', "corrections=$Corrections", '--input', "implementer_session=$implementerSession",
            '--input', "continue_runner=$(Join-Path $PSScriptRoot 'scripts\Resume-ArchonImplementer.ps1')")
    }
    & $archon workflow run feature-review --folder --cwd $root --config $settings `
        --workflow-source $PSScriptRoot @inputs
    if ($LASTEXITCODE -ne 0) { throw 'The Archon workflow failed. Inspect the run before continuing.' }
} finally {
    $env:CODEX_BIN_PATH = $priorCodex
    $env:PATH = $priorPath
}
