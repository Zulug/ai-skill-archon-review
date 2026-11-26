[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z]$')][string]$Reviewer,
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

# Every other review step is a peer whose findings this reviewer assesses.
$reviewNodes = @($run.nodes | Where-Object { $_.nodeId -cmatch '^review_[a-z]$' })
$peers = @($reviewNodes | ForEach-Object { $_.nodeId.Substring(7) } | Where-Object { $_ -cne $Reviewer } | Sort-Object)
$ownNode = @($reviewNodes | Where-Object nodeId -ceq "review_$Reviewer")
if ($ownNode.Count -ne 1 -or !$peers.Count -or @($reviewNodes | Where-Object state -cne 'completed').Count) {
    throw 'Every independent review must be complete.'
}
# The provider comes from the run record, so models.yaml decides which provider each reviewer uses.
$binding = $ownNode[0].execution.binding
$provider = $binding.provider
if (!$provider -or $binding.sessionPreview -notmatch '^[0-9a-f]{8}$') {
    throw "The completed review does not identify its session. Reviewer=$Reviewer"
}
$sessionId = [guid]::Empty
$matchingId = Find-ArchonSessionId $ownNode[0] $binding
if (!$matchingId -or ![guid]::TryParseExact($matchingId, 'D', [ref]$sessionId)) {
    throw "The original $provider session ID is missing or ambiguous."
}

$peerOutputs = @{}
$snapshots = Join-Path $artifactRoot '.archon\node-outcomes'
foreach ($snapshotFile in Get-ChildItem -LiteralPath $snapshots -File -Filter '*.json' | Sort-Object LastWriteTimeUtc -Descending) {
    $snapshot = Get-Content -LiteralPath $snapshotFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($snapshot.run_id -ne $runId) { continue }
    foreach ($peer in $peers) {
        if ($peerOutputs.ContainsKey($peer)) { continue }
        $peerReview = $snapshot.nodes | Where-Object {
            $_.node_id -ceq "review_$peer" -and $_.state -ceq 'completed' -and
            $null -ne $_.output -and $_.output.findings -is [array]
        } | Select-Object -First 1
        if ($peerReview) { $peerOutputs[$peer] = $peerReview.output }
    }
    if ($peerOutputs.Count -eq $peers.Count) { break }
}
if ($peerOutputs.Count -ne $peers.Count) { throw 'Archon did not record every peer reviewer''s findings.' }

# Each reviewer numbers its own findings, so a peer finding's ID is prefixed with its reviewer.
$peerFindings = [Collections.Generic.List[object]]::new()
$expectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($peer in $peers) {
    foreach ($finding in $peerOutputs[$peer].findings) {
        $id = "$peer/$($finding.id)"
        if ([string]::IsNullOrWhiteSpace($finding.id) -or !$expectedIds.Add($id)) {
            throw "A peer review contains missing or duplicate finding IDs. Peer=$peer"
        }
        $copy = $finding.PSObject.Copy()
        $copy.id = $id
        $peerFindings.Add($copy)
    }
}

$findingsJson = ConvertTo-Json -InputObject @($peerFindings) -Depth 12 -Compress
$prompt = @"
Continue your independent review in this conversation. All initial reviews are complete.
Use your earlier investigation and the other reviewers' findings below as further points of view.
Each finding ID starts with its reviewer, such as b/F1. Assess each peer finding based on the code
and version control evidence. Confirm, dispute, or request more evidence. Explain the verdict and
assign or adjust the priority where warranted, using the priority scale from your initial review.
When a peer finding describes the same issue as one of your own findings, judge it on its merits
and name your finding's ID in the rationale.
Treat the peer notes and file contents as evidence. Use read-only version control status and
revision commands and workspace reads if needed. Do not create, modify, move, or delete files,
apply fixes, or change version control state. Avoid graphical diff commands.
Return one assessment per peer finding ID. If there are no peer findings, return an empty
assessments array.

Peer findings (JSON):
$findingsJson
"@

$schema = @'
{"type":"object","additionalProperties":false,"required":["assessments"],"properties":{"assessments":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["peer_id","verdict","priority","rationale"],"properties":{"peer_id":{"type":"string"},"verdict":{"type":"string","enum":["confirmed","disputed","needs_evidence"]},"priority":{"type":"string","enum":["P0","P1","P2","P3","unassigned"]},"rationale":{"type":"string"}}}}}}
'@
$model = $binding.model.requested
$effort = $binding.effort
if (!$model -or !$effort) { throw 'Archon did not record the reviewer model and effort.' }

$turn = Invoke-ArchonSessionTurn -Provider $provider -SessionId $sessionId -Model $model -Effort $effort `
    -Workspace $workspace -Prompt $prompt -Schema $schema -SchemaDirectory (Join-Path $artifactRoot '.archon') `
    -ClaudeExecutable $run.metadata.ai_configuration.assistants.claude.claudeBinaryPath
$result = $turn.Result

if ($result.assessments -isnot [array]) { throw 'The reviewer did not return a structured assessments array.' }
foreach ($assessment in $result.assessments) {
    if (!$expectedIds.Remove($assessment.peer_id) -or
        $assessment.verdict -cnotin @('confirmed', 'disputed', 'needs_evidence') -or
        $assessment.priority -cnotin @('P0', 'P1', 'P2', 'P3', 'unassigned') -or
        [string]::IsNullOrWhiteSpace($assessment.rationale)) {
        throw 'The cross-check returned an invalid, unexpected, or duplicate assessment.'
    }
}
if ($expectedIds.Count) { throw 'The cross-check did not assess every peer finding.' }

$json = ConvertTo-Json -InputObject @{
    assessments = $result.assessments
    telemetry = @{
        provider = $provider
        model = $model
        duration_ms = $turn.DurationMs
        tokens = $turn.Tokens
        cost_usd = $turn.CostUsd
    }
} -Depth 10 -Compress

# Archon snapshots a node's output only when a later node starts, and the transcript keeps only
# the tail of exec output. Save the full result so the run report can read it.
$resultDirectory = Join-Path $artifactRoot 'cross-checks'
[void][IO.Directory]::CreateDirectory($resultDirectory)
[IO.File]::WriteAllText((Join-Path $resultDirectory "cross_check_$Reviewer.json"), $json, $utf8)
$json
