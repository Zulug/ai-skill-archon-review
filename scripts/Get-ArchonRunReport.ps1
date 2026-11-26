[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Transcript,
    # Archon finds the run record only from the workspace it ran in.
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArchonSession.ps1')
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

# The reviewers are the run's review steps, whether they ran or were skipped.
$reviewers = @($events | Where-Object { $_.step -cmatch '^review_[a-z]$' } | ForEach-Object { $_.step.Substring(7) } |
    Sort-Object -Unique)
$expected = @{}
foreach ($reviewer in $reviewers) {
    $expected["review_$reviewer"] = 'findings'
    $expected["cross_check_$reviewer"] = 'assessments'
}
$outputs = @{}
# The cross-check runner saves its full result. Archon snapshots a node's output only when a
# later node starts, so no snapshot holds the final cross-checks.
foreach ($id in @($reviewers | ForEach-Object { "cross_check_$_" })) {
    $file = Join-Path $artifactDir "cross-checks\$id.json"
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $saved = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.PSObject.Properties['assessments']) { $outputs[$id] = $saved }
    }
}
# The continue step saves its full result too, because a blocked answer starts no later node.
$continueFile = Join-Path $artifactDir 'implementer\continue.json'
if (Test-Path -LiteralPath $continueFile -PathType Leaf) {
    $saved = Get-Content -LiteralPath $continueFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.PSObject.Properties['status']) { $outputs['continue'] = $saved }
}
# Archon records the structured review outputs in cumulative node snapshots. Older runs also
# have cross-check outputs there, captured when a later triage node started.
$implementOutput = $null
$snapshotDir = Join-Path $artifactDir '.archon\node-outcomes'
if (Test-Path -LiteralPath $snapshotDir -PathType Container) {
    foreach ($file in (Get-ChildItem -LiteralPath $snapshotDir -File -Filter '*.json' | Sort-Object LastWriteTimeUtc -Descending)) {
        $snapshot = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($snapshot.run_id -ne $start.workflow_id) { continue }
        foreach ($node in $snapshot.nodes) {
            $id = $node.node_id
            if ($id -eq 'implement' -and !$implementOutput -and $node.state -eq 'completed' -and
                $node.output.PSObject.Properties['status']) {
                $implementOutput = $node.output
            }
            if ($id -and $expected.ContainsKey($id) -and -not $outputs.ContainsKey($id) -and
                $node.state -eq 'completed' -and $null -ne $node.output -and $node.output.PSObject.Properties[$expected[$id]]) {
                $outputs[$id] = $node.output
            }
        }
        if ($outputs.Count -eq $expected.Count -and $implementOutput) { break }
    }
}
# A blocked run starts no node after implement, so no snapshot holds its answer. Codex sends
# its structured answer as the step's last message.
if (!$implementOutput) {
    $lastMessage = ($events | Where-Object { $_.step -eq 'implement' -and $_.event.type -eq 'agent_message_chunk' } |
        Select-Object -Last 1).event.text
    if ($lastMessage) {
        try { $parsed = $lastMessage | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
        if ($parsed -and $parsed.PSObject.Properties['status']) { $implementOutput = $parsed }
    }
}

# A finding's priority is the median of its votes: the finder's proposed priority and each peer's
# verdict. Disputes and requests for evidence rank below P3, and with an even number of votes the
# lower middle vote wins. docs/multi-reviewer-design.md explains the rule.
$voteRank = @{ P0 = 0; P1 = 1; P2 = 2; P3 = 3; dispute = 4; needs_evidence = 4 }
function Get-MedianPriority([string[]]$Votes) {
    $sorted = @($Votes | Sort-Object { $voteRank[$_] })
    $median = $sorted[[math]::Floor($sorted.Count / 2)]
    if ($voteRank[$median] -lt 4) { return $median }
    # Both rank last; name the more common one, and a tie a dispute.
    $unconfirmed = @($sorted | Where-Object { $voteRank[$_] -eq 4 })
    $evidence = @($unconfirmed | Where-Object { $_ -ceq 'needs_evidence' }).Count
    if ($evidence -gt $unconfirmed.Count - $evidence) { 'needs_evidence' } else { 'dispute' }
}

# Every finding carries each peer's verdict, so disputed and unassessed findings stay visible.
# A lost cross-check output is not a peer decision, so it gets its own verdict, and the finding's
# priority is unknown.
$findings = @(foreach ($origin in $reviewers) {
    foreach ($finding in $outputs["review_$origin"].findings) {
        $key = "$origin/$($finding.id)"
        $votes = [Collections.Generic.List[string]]::new()
        $votes.Add($finding.priority)
        $complete = $true
        $assessments = @(foreach ($peer in @($reviewers | Where-Object { $_ -cne $origin })) {
            $check = $outputs["cross_check_$peer"]
            # Runs with two reviewers assessed unprefixed IDs.
            $found = @($check.assessments | Where-Object { $_.peer_id -ceq $key -or $_.peer_id -ceq $finding.id })
            $assessment = if ($found.Count -eq 1) { $found[0] }
            $verdict = if ($assessment) { $assessment.verdict } elseif ($check) { 'not_assessed' } else { 'cross_check_unavailable' }
            $vote = switch -CaseSensitive ($verdict) {
                # A confirmation without a priority accepts the proposed one.
                'confirmed' { if ($assessment.priority -cin @('P0', 'P1', 'P2', 'P3')) { $assessment.priority } else { $finding.priority } }
                'disputed' { 'dispute' }
                'needs_evidence' { 'needs_evidence' }
                default { $null }
            }
            if ($vote) { $votes.Add($vote) } else { $complete = $false }
            [pscustomobject]@{
                Reviewer = "review_$peer"
                Verdict = $verdict
                Priority = $(if ($assessment) { $assessment.priority })
                Rationale = $(if ($assessment) { $assessment.rationale })
            }
        })
        [pscustomobject]@{
            Origin = "review_$origin"
            Id = $finding.id
            Key = $key
            Location = $finding.location
            Evidence = $finding.evidence
            Impact = $finding.impact
            ProposedFix = $finding.proposed_fix
            ProposedPriority = $finding.priority
            Assessments = $assessments
            Votes = @($votes)
            Priority = $(if ($complete) { Get-MedianPriority $votes } else { 'unknown' })
        }
    }
})

$steps = @(foreach ($node in ($events | Where-Object type -eq 'node_complete')) {
    $binding = $node.execution.binding
    $resumeTurn = $outputs[$node.step].telemetry
    if (!$binding.provider -and !$resumeTurn) { continue }
    $model = $binding.model
    $durationMs = if ($resumeTurn) { $resumeTurn.duration_ms } else { $node.duration_ms }
    [pscustomobject]@{
        Step = $node.step
        Provider = if ($resumeTurn) { $resumeTurn.provider } else { $binding.provider }
        Model = if ($resumeTurn) { $resumeTurn.model } elseif ($model.resolved.value) { $model.resolved.value } else { $model.requested }
        DurationSeconds = $(if ($null -ne $durationMs) { [math]::Round($durationMs / 1000, 3) })
        Tokens = if ($resumeTurn) { Read-TokenUsage $resumeTurn.tokens } else { Read-TokenUsage $node.tokens }
        RecordedUsd = if ($resumeTurn) { $resumeTurn.cost_usd } else { $node.cost_usd }
        FindingsCount = $(if ($outputs[$node.step] -and $expected[$node.step] -eq 'findings') { @($outputs[$node.step].findings).Count })
        AssessmentsCount = $(if ($outputs[$node.step] -and $expected[$node.step] -eq 'assessments') { @($outputs[$node.step].assessments).Count })
        UsageNote = $null
    }
})

# Codex reports session-to-date tokens on resume, and Claude reports session-to-date cost.
# Subtract the session's earlier turns so each resumed step shows its own usage.
$problems = [Collections.Generic.List[string]]::new()
function Set-ResumedTurnUsage($Step, $PriorTokens, $PriorUsd, [string]$PriorLabel) {
    if ($Step.Provider -eq 'codex') {
        $turn = if ($PriorTokens) { Get-UsageDelta $Step.Tokens $PriorTokens }
        if ($turn) {
            $Step.Tokens = $turn
            $Step.UsageNote = "Tokens derived: session total minus $PriorLabel."
        } elseif ($Step.Tokens) {
            $Step.UsageNote = "Tokens are the session total, including $PriorLabel."
            $problems.Add("$($Step.Step) tokens are the session total; token totals also count $PriorLabel.")
        }
    } elseif ($Step.Provider -eq 'claude' -and $null -ne $Step.RecordedUsd) {
        if ($null -ne $PriorUsd -and [decimal]$Step.RecordedUsd -ge [decimal]$PriorUsd) {
            $Step.RecordedUsd = [decimal]$Step.RecordedUsd - [decimal]$PriorUsd
            $Step.UsageNote = "Cost derived: session total minus $PriorLabel."
        } else {
            $Step.UsageNote = "Cost is the session total, including $PriorLabel."
            $problems.Add("$($Step.Step) cost is the session total; the cost total also counts $PriorLabel.")
        }
    }
}
foreach ($check in @($steps | Where-Object { $_.Step -like 'cross_check_*' })) {
    $reviewStep = 'review_' + $check.Step.Substring($check.Step.Length - 1)
    $review = $steps | Where-Object Step -eq $reviewStep | Select-Object -First 1
    Set-ResumedTurnUsage $check $review.Tokens $review.RecordedUsd $reviewStep
}
# The continue step's earlier turns ran in earlier runs, so it recorded their usage itself.
$continueTelemetry = $outputs['continue'].telemetry
foreach ($step in @($steps | Where-Object Step -eq 'continue')) {
    Set-ResumedTurnUsage $step (Read-TokenUsage $continueTelemetry.prior_tokens) $continueTelemetry.prior_cost_usd 'the earlier implementer turns'
}

$tokenTotals = Read-TokenUsage $done.tokens
$recordedUsd = $done.cost_usd
$tokenFields = @('Input', 'CachedInput', 'UncachedInput', 'InputCacheWrites', 'Output', 'CachedOutput', 'UncachedOutput')
$missingTokenSteps = [ordered]@{}
foreach ($field in $tokenFields) {
    $missingTokenSteps[$field] = @($steps | Where-Object { $null -eq $_.Tokens.$field } | ForEach-Object Step)
}
if ($done -and @($outputs.Values | Where-Object { $_.telemetry }).Count) {
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

# Resuming the implementer's own session lets the user ask why it wrote the code as it did, and
# lets a later run continue it with corrections. A continue step recorded its session itself;
# for the implement step, the transcript keeps only a session ID prefix, so the full ID comes
# from Archon's run record.
$implementer = $null
$implementNode = $events | Where-Object { $_.type -eq 'node_complete' -and $_.step -in @('implement', 'continue') } |
    Select-Object -Last 1
if ($implementNode) {
    $root = (Get-Item -LiteralPath $Workspace).FullName
    $continued = $implementNode.step -eq 'continue'
    if ($continued) { $implementOutput = $outputs['continue'] }
    $binding = $implementNode.execution.binding
    # A blocked implementer skips the review; the user answers its questions by rerunning.
    $implementer = [pscustomobject]@{
        Step = $implementNode.step
        Status = $implementOutput.status
        Summary = $implementOutput.summary
        Assumptions = @($implementOutput.assumptions | Where-Object { $_ })
        Questions = @($implementOutput.questions | Where-Object { $_ })
        Provider = if ($continued) { $continueTelemetry.provider } else { $binding.provider }
        Model = if ($continued) { $continueTelemetry.model } else { $binding.model.requested }
        Effort = if ($continued) { $continueTelemetry.effort } else { $binding.effort }
        SessionId = $(if ($continued) { $continueTelemetry.session_id })
        # Usage to date of the whole session, which a later continuation subtracts from its own.
        SessionUsage = [pscustomobject]@{
            Tokens = if ($continued) { $continueTelemetry.tokens } else { $implementNode.tokens }
            CostUsd = if ($continued) { $continueTelemetry.cost_usd } else { $implementNode.cost_usd }
        }
        ResumeCommand = $null
        Note = $null
    }
    if (!$implementOutput) { $problems.Add('The implementer''s answer is missing, so its status is unknown.') }
    if (!$continued) {
        $run = Get-ArchonRunRecord $runId $root
        if (!$run) {
            $implementer.Note = "Archon has no record of this run for the workspace. Workspace=$root"
        } else {
            $node = $run.nodes | Where-Object nodeId -ceq 'implement' | Select-Object -First 1
            $implementer.SessionId = Find-ArchonSessionId $node $binding
            if (!$implementer.SessionId) { $implementer.Note = 'The implementer session ID is missing or ambiguous.' }
        }
    } elseif (!$implementer.SessionId) {
        $implementer.Note = 'The continue step did not record the implementer session.'
    }
    if ($implementer.SessionId -and $implementer.Status -ne 'blocked') {
        $quotedRoot = "'" + $root.Replace("'", "''") + "'"
        if ($implementer.Provider -eq 'codex') {
            $codexPath = Get-CodexExecutable
            if (!$codexPath) { $codexPath = 'codex' }
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

$missingOutputs = @(if ($implementer.Status -ne 'blocked') {
    $expected.Keys | Where-Object { -not $outputs.ContainsKey($_) } | Sort-Object
})
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
