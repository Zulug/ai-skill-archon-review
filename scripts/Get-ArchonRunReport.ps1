[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Transcript,
    # Archon finds the run record only from the workspace it ran in.
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$log = Get-Item -LiteralPath $Transcript
$events = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8 | ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) { ConvertFrom-Json -InputObject $_ }
})
$start = $events | Where-Object type -eq 'workflow_start' | Select-Object -First 1
if (-not $start -or $start.workflow_name -ne 'feature-review') {
    throw 'Use the JSONL transcript of a feature-review run.'
}
$runId = [guid]::Empty
if (-not [guid]::TryParse($start.workflow_id, [ref]$runId)) { throw 'The Archon run ID is missing or invalid.' }
$done = $events | Where-Object type -eq 'workflow_complete' | Select-Object -Last 1
$artifactDir = Join-Path $log.Directory.Parent.FullName "artifacts\runs\$runId"

function Read-TokenUsage($Tokens) {
    if ($null -eq $Tokens) { return $null }
    $cachedOutput = $Tokens.cacheReadOutput
    if ($null -eq $cachedOutput) { $cachedOutput = $Tokens.cachedOutput }
    [pscustomobject]@{
        Input = $Tokens.input
        CachedInput = $Tokens.cacheRead
        UncachedInput = $(if ($null -ne $Tokens.input -and $null -ne $Tokens.cacheRead) { $Tokens.input - $Tokens.cacheRead })
        InputCacheWrites = $Tokens.cacheWrite
        Output = $Tokens.output
        CachedOutput = $cachedOutput
        UncachedOutput = $(if ($null -ne $Tokens.output -and $null -ne $cachedOutput) { $Tokens.output - $cachedOutput })
    }
}

# Resumed sessions report usage to date, which includes the original review turn.
function Get-UsageDelta($Total, $Prior) {
    $delta = @{}
    foreach ($field in @('Input', 'CachedInput', 'InputCacheWrites', 'Output', 'CachedOutput')) {
        if ($null -eq $Total.$field) { $delta[$field] = $null; continue }
        if ($null -eq $Prior.$field -or $Total.$field -lt $Prior.$field) { return $null }
        $delta[$field] = $Total.$field - $Prior.$field
    }
    Read-TokenUsage @{
        input = $delta.Input; cacheRead = $delta.CachedInput; cacheWrite = $delta.InputCacheWrites
        output = $delta.Output; cacheReadOutput = $delta.CachedOutput
    }
}

$expected = @{ review_a = 'findings'; review_b = 'findings'; cross_check_a = 'assessments'; cross_check_b = 'assessments' }
$outputs = @{}
# The cross-check runner saves its full result. Archon snapshots a node's output only when a
# later node starts, so no snapshot holds the final cross-checks.
foreach ($id in @('cross_check_a', 'cross_check_b')) {
    $file = Join-Path $artifactDir "cross-checks\$id.json"
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $saved = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.PSObject.Properties['assessments']) { $outputs[$id] = $saved }
    }
}
# Archon records the structured review outputs in cumulative node snapshots. Older runs also
# have cross-check outputs there, captured when a later triage node started.
$snapshotDir = Join-Path $artifactDir '.archon\node-outcomes'
if (Test-Path -LiteralPath $snapshotDir -PathType Container) {
    foreach ($file in (Get-ChildItem -LiteralPath $snapshotDir -File -Filter '*.json' | Sort-Object LastWriteTimeUtc -Descending)) {
        $snapshot = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($snapshot.run_id -ne $start.workflow_id) { continue }
        foreach ($node in $snapshot.nodes) {
            $id = $node.node_id
            if ($id -and $expected.ContainsKey($id) -and -not $outputs.ContainsKey($id) -and
                $node.state -eq 'completed' -and $null -ne $node.output -and $node.output.PSObject.Properties[$expected[$id]]) {
                $outputs[$id] = $node.output
            }
        }
        if ($outputs.Count -eq $expected.Count) { break }
    }
}

# Every finding carries the peer's verdict, so disputed and unassessed findings stay visible.
# A lost cross-check output is not a peer decision, so it gets its own verdict.
$findings = @(foreach ($origin in @('a', 'b')) {
    $peer = if ($origin -eq 'a') { 'b' } else { 'a' }
    $review = $outputs["review_$origin"]
    $check = $outputs["cross_check_$peer"]
    foreach ($finding in $review.findings) {
        $assessments = @($check.assessments | Where-Object { $_.peer_id -ceq $finding.id })
        $assessment = if ($assessments.Count -eq 1) { $assessments[0] }
        $verdict = if ($assessment) { $assessment.verdict } elseif ($check) { 'not_assessed' } else { 'cross_check_unavailable' }
        [pscustomobject]@{
            Origin = "review_$origin"
            AssessedBy = "cross_check_$peer"
            Id = $finding.id
            Location = $finding.location
            Evidence = $finding.evidence
            Impact = $finding.impact
            ProposedFix = $finding.proposed_fix
            ProposedPriority = $finding.priority
            Verdict = $verdict
            PeerPriority = $(if ($assessment) { $assessment.priority })
            PeerRationale = $(if ($assessment) { $assessment.rationale })
        }
    }
})

$steps = @(foreach ($node in ($events | Where-Object type -eq 'node_complete')) {
    $binding = $node.execution.binding
    $resumeTurn = $outputs[$node.step].telemetry
    if (!$binding.provider -and !$resumeTurn) { continue }
    $model = $binding.model
    $durationMs = if ($resumeTurn) { $resumeTurn.duration_ms } else { $node.duration_ms }
    $response = $null
    if ($node.step -eq 'implement') {
        $response = ($events | Where-Object { $_.step -eq 'implement' -and $_.event.type -eq 'agent_message_chunk' } |
            Select-Object -Last 1).event.text
    }
    [pscustomobject]@{
        Step = $node.step
        Provider = if ($resumeTurn) { $resumeTurn.provider } else { $binding.provider }
        Model = if ($resumeTurn) { $resumeTurn.model } elseif ($model.resolved.value) { $model.resolved.value } else { $model.requested }
        DurationSeconds = $(if ($null -ne $durationMs) { [math]::Round($durationMs / 1000, 3) })
        Tokens = if ($resumeTurn) { Read-TokenUsage $resumeTurn.tokens } else { Read-TokenUsage $node.tokens }
        RecordedUsd = if ($resumeTurn) { $resumeTurn.cost_usd } else { $node.cost_usd }
        Response = $response
        FindingsCount = $(if ($outputs[$node.step] -and $expected[$node.step] -eq 'findings') { @($outputs[$node.step].findings).Count })
        AssessmentsCount = $(if ($outputs[$node.step] -and $expected[$node.step] -eq 'assessments') { @($outputs[$node.step].assessments).Count })
        UsageNote = $null
    }
})

# Codex reports session-to-date tokens on resume, and Claude reports session-to-date cost.
# Subtract the original review turn so each cross-check shows its own usage.
$problems = [Collections.Generic.List[string]]::new()
foreach ($check in @($steps | Where-Object { $_.Step -like 'cross_check_*' })) {
    $reviewStep = 'review_' + $check.Step.Substring($check.Step.Length - 1)
    $review = $steps | Where-Object Step -eq $reviewStep | Select-Object -First 1
    if ($check.Provider -eq 'codex') {
        $turn = if ($review) { Get-UsageDelta $check.Tokens $review.Tokens }
        if ($turn) {
            $check.Tokens = $turn
            $check.UsageNote = "Tokens derived: session total minus $reviewStep."
        } elseif ($check.Tokens) {
            $check.UsageNote = 'Tokens are the session total, including the review turn.'
            $problems.Add("$($check.Step) tokens are the session total; token totals count $reviewStep twice.")
        }
    } elseif ($check.Provider -eq 'claude' -and $null -ne $check.RecordedUsd) {
        if ($review -and $null -ne $review.RecordedUsd -and [decimal]$check.RecordedUsd -ge [decimal]$review.RecordedUsd) {
            $check.RecordedUsd = [decimal]$check.RecordedUsd - [decimal]$review.RecordedUsd
            $check.UsageNote = "Cost derived: session total minus $reviewStep."
        } else {
            $check.UsageNote = 'Cost is the session total, including the review turn.'
            $problems.Add("$($check.Step) cost is the session total; the cost total counts $reviewStep twice.")
        }
    }
}

$tokenTotals = Read-TokenUsage $done.tokens
$recordedUsd = $done.cost_usd
$tokenFields = @('Input', 'CachedInput', 'UncachedInput', 'InputCacheWrites', 'Output', 'CachedOutput', 'UncachedOutput')
$missingTokenSteps = [ordered]@{}
foreach ($field in $tokenFields) {
    $missingTokenSteps[$field] = @($steps | Where-Object { $null -eq $_.Tokens.$field } | ForEach-Object Step)
}
if ($done -and ($outputs.cross_check_a.telemetry -or $outputs.cross_check_b.telemetry)) {
    # Archon's workflow totals omit provider turns executed by bash nodes.
    $tokenTotals = [ordered]@{}
    foreach ($field in $tokenFields) {
        $known = @($steps | ForEach-Object { $_.Tokens.$field } | Where-Object { $null -ne $_ })
        $tokenTotals[$field] = if ($known.Count) { [long](($known | Measure-Object -Sum).Sum) }
    }
    $costs = @($steps | ForEach-Object RecordedUsd | Where-Object { $null -ne $_ })
    $recordedUsd = if ($costs.Count) {
        $totalCost = [decimal]0
        foreach ($cost in $costs) { $totalCost += [decimal]$cost }
        $totalCost
    }
}

# Resuming the implementer's own session lets the user ask why it wrote the code as it did.
# The transcript keeps only a session ID prefix, so the full ID comes from Archon's run record.
$implementer = $null
$implementNode = $events | Where-Object { $_.type -eq 'node_complete' -and $_.step -eq 'implement' } | Select-Object -Last 1
if ($implementNode) {
    $binding = $implementNode.execution.binding
    $implementer = [pscustomobject]@{
        Provider = $binding.provider
        Model = $binding.model.requested
        Effort = $binding.effort
        SessionId = $null
        ResumeCommand = $null
        Note = $null
    }
    $root = (Get-Item -LiteralPath $Workspace).FullName
    $archonCommand = Get-Command archon.exe -ErrorAction SilentlyContinue
    $archon = if ($archonCommand) { $archonCommand.Source } else { Join-Path $env:USERPROFILE '.archon\bin\archon.exe' }
    # Windows PowerShell turns redirected native stderr into errors under 'Stop'.
    $runJson = & { $ErrorActionPreference = 'Continue'; & $archon workflow get $runId.ToString() --verbose --json --cwd $root 2>$null }
    $run = if ($LASTEXITCODE -eq 0 -and $runJson) { ($runJson -join [Environment]::NewLine) | ConvertFrom-Json }
    if (!$run -or $run.id -ne $runId -or $run.working_path -ine $root) {
        $implementer.Note = "Archon has no record of this run for the workspace. Workspace=$root"
    } else {
        $node = $run.nodes | Where-Object nodeId -ceq 'implement' | Select-Object -First 1
        $ids = @($node.sessionIds | Where-Object {
            $_ -is [string] -and $binding.sessionPreview -and $_.StartsWith($binding.sessionPreview, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($ids.Count -eq 1) { $implementer.SessionId = $ids[0] }
        else { $implementer.Note = 'The implementer session ID is missing or ambiguous.' }
    }
    if ($implementer.SessionId) {
        $quotedRoot = "'" + $root.Replace("'", "''") + "'"
        if ($implementer.Provider -eq 'codex') {
            $codex = Get-Command codex.exe -ErrorAction SilentlyContinue
            $codexPath = if ($codex) { $codex.Source } else {
                $app = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue
                if ($app) { Join-Path $app.InstallLocation 'app\resources\codex.exe' } else { 'codex' }
            }
            $command = "& '$($codexPath.Replace("'", "''"))' resume $($implementer.SessionId) -C $quotedRoot -s read-only"
            if ($implementer.Model) { $command += " -m $($implementer.Model)" }
            if ($implementer.Effort) { $command += " -c model_reasoning_effort=$($implementer.Effort)" }
        } elseif ($implementer.Provider -eq 'claude') {
            # Claude finds a session from the directory it ran in. Plan mode keeps it read-only.
            $command = "Set-Location -LiteralPath $quotedRoot; claude --resume $($implementer.SessionId) --permission-mode plan"
            if ($implementer.Model) { $command += " --model $($implementer.Model)" }
            if ($implementer.Effort) { $command += " --effort $($implementer.Effort)" }
        } else {
            $command = $null
            $implementer.Note = "No resume command for provider $($implementer.Provider)."
        }
        $implementer.ResumeCommand = $command
    }
}

$missingOutputs = @($expected.Keys | Where-Object { -not $outputs.ContainsKey($_) } | Sort-Object)
if ($done -and $missingOutputs.Count) {
    $problems.Insert(0, "The run completed, but these outputs are missing: $($missingOutputs -join ', '). Their verdicts are unknown.")
}

[pscustomobject]@{
    RunId = $start.workflow_id
    Completed = [bool]$done
    WallSeconds = $(if ($done) { [math]::Round((([datetimeoffset]$done.ts) - ([datetimeoffset]$start.ts)).TotalSeconds, 3) })
    Tokens = $tokenTotals
    RecordedUsd = $recordedUsd
    MissingCostSteps = @($steps | Where-Object { $null -eq $_.RecordedUsd } | ForEach-Object Step)
    MissingTokenSteps = $missingTokenSteps
    MissingReviewOutputs = $missingOutputs
    Problems = @($problems)
    Steps = $steps
    Findings = $findings
    Implementer = $implementer
    Transcript = $log.FullName
} | ConvertTo-Json -Depth 10
