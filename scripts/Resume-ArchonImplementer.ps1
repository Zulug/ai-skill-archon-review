# Continues an earlier run's implementer session with corrections, as the workflow's continue
# step. Invoke-ArchonReview.ps1 passes the session through workflow inputs, which Archon gives
# bash steps as environment variables, so multiline corrections need no command-line quoting.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArchonSession.ps1')
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8

$workspace = (Get-Location).ProviderPath
$artifactRoot = (Get-Item -LiteralPath $ArtifactDirectory).FullName
$runId = [guid]::Empty
if (![guid]::TryParse((Split-Path -Leaf $artifactRoot), [ref]$runId)) {
    throw 'The Archon artifact directory has no valid run ID.'
}
$run = Get-ArchonRunRecord $runId $workspace
if (!$run -or $run.workflow_name -cne 'feature-review') {
    throw "The Archon run does not match the current workspace. Workspace=$workspace"
}

$corrections = $env:INPUTS_CORRECTIONS
if ([string]::IsNullOrWhiteSpace($corrections)) { throw 'The continue step needs corrections.' }
if ([string]::IsNullOrWhiteSpace($env:INPUTS_IMPLEMENTER_SESSION)) { throw 'The continue step needs the implementer session.' }
$session = $env:INPUTS_IMPLEMENTER_SESSION | ConvertFrom-Json
$sessionId = [guid]::Empty
if (![guid]::TryParseExact([string]$session.session_id, 'D', [ref]$sessionId) -or
    !$session.provider -or !$session.model -or !$session.effort) {
    throw "The implementer session is incomplete. Provider=$($session.provider)"
}

$prompt = @"
Continue your implementation in this conversation. Reviewers checked the changes in the
current workspace, and these corrections are needed:

$corrections

The rules of your original request still apply. Nobody can answer questions while you work.
Return status blocked without changing anything only when a correction has several reasonable
readings that lead to materially different changes and the code, the instruction files, and
the guidelines they reference do not settle which one is meant; list the questions the user
must answer. For smaller gaps, choose the most reasonable reading and record it in
assumptions. Leave every change uncommitted. Do not commit, check in, stash, shelve, push,
create or switch branches, or change the workspace's base revision. Preserve unrelated
uncommitted changes. Do not write handover or notes files; your response is the handover.
When implemented, summarize what this turn changed and the checks you ran, and put anything
the human reviewer should decide or know in questions.
"@

# The implement step's output schema, so both steps report the implementer the same way.
$schema = @'
{"type":"object","additionalProperties":false,"required":["status","summary","assumptions","questions"],"properties":{"status":{"type":"string","enum":["implemented","blocked"]},"summary":{"type":"string"},"assumptions":{"type":"array","items":{"type":"string"}},"questions":{"type":"array","items":{"type":"string"}}}}
'@

$turn = Invoke-ArchonSessionTurn -Provider $session.provider -SessionId $sessionId -Model $session.model `
    -Effort $session.effort -Workspace $workspace -Prompt $prompt -Schema $schema `
    -SchemaDirectory (Join-Path $artifactRoot '.archon') -WriteAccess `
    -ClaudeExecutable $run.metadata.ai_configuration.assistants.claude.claudeBinaryPath
$result = $turn.Result
if ($result.status -cnotin @('implemented', 'blocked') -or [string]::IsNullOrWhiteSpace($result.summary) -or
    $result.assumptions -isnot [array] -or $result.questions -isnot [array]) {
    throw 'The implementer did not return a structured answer.'
}

# Resumed sessions report usage to date. The earlier turns' usage lets the run report show
# this turn's own usage and lets a later continuation do the same.
$json = ConvertTo-Json -InputObject @{
    status = $result.status
    summary = $result.summary
    assumptions = $result.assumptions
    questions = $result.questions
    telemetry = @{
        provider = $session.provider
        model = $session.model
        effort = $session.effort
        session_id = $sessionId.ToString()
        duration_ms = $turn.DurationMs
        tokens = $turn.Tokens
        cost_usd = $turn.CostUsd
        prior_tokens = $session.prior_tokens
        prior_cost_usd = $session.prior_cost_usd
    }
} -Depth 10 -Compress

# A blocked answer starts no later step, so no node snapshot would hold it. Save the result
# so the run report can read it.
$resultDirectory = Join-Path $artifactRoot 'implementer'
[void][IO.Directory]::CreateDirectory($resultDirectory)
[IO.File]::WriteAllText((Join-Path $resultDirectory 'continue.json'), $json, $utf8)
$json
