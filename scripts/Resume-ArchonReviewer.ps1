[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('a', 'b')][string]$Reviewer,
    [Parameter(Mandatory)][string]$ArtifactDirectory
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8

# Use the same Windows argument quoting with Windows PowerShell and PowerShell 7.
# The prompt goes over UTF-8 stdin, so peer notes cannot become command arguments.
function Invoke-ReviewerProcess([string]$Executable, [string[]]$Arguments, [string]$Prompt) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $workspace
    $info.Arguments = ($Arguments | ForEach-Object {
        '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    if ($provider -ceq 'claude') { $info.EnvironmentVariables.Remove('CLAUDECODE') }

    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $bytes = $utf8.GetBytes($Prompt)
        $stdin = $process.StandardInput.BaseStream
        try {
            $stdin.Write($bytes, 0, $bytes.Length)
        } finally {
            $stdin.Close()
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "$provider failed to resume its original session (exit $($process.ExitCode)). $($stderr.GetAwaiter().GetResult().Trim())"
        }
        $stdout.GetAwaiter().GetResult()
    } finally {
        $process.Dispose()
    }
}

$workspace = (Get-Location).ProviderPath
$artifactRoot = (Get-Item -LiteralPath $ArtifactDirectory).FullName
$runId = [guid]::Empty
if (![guid]::TryParse((Split-Path -Leaf $artifactRoot), [ref]$runId)) {
    throw 'The Archon artifact directory has no valid run ID.'
}

$provider = if ($Reviewer -eq 'a') { 'codex' } else { 'claude' }
$peer = if ($Reviewer -eq 'a') { 'b' } else { 'a' }
$archonCommand = Get-Command archon.exe -ErrorAction SilentlyContinue
$archon = if ($archonCommand) { $archonCommand.Source } else { Join-Path $env:USERPROFILE '.archon\bin\archon.exe' }
$runJson = & $archon workflow get $runId.ToString() --verbose --json
if ($LASTEXITCODE -ne 0) { throw 'Archon could not read the reviewer session records.' }
$run = ($runJson -join [Environment]::NewLine) | ConvertFrom-Json
if ($run.id -ne $runId -or $run.workflow_name -cne 'feature-review' -or $run.working_path -ine $workspace) {
    throw "The Archon run does not match the current workspace. Workspace=$workspace"
}

$ownNode = @($run.nodes | Where-Object { $_.nodeId -ceq "review_$Reviewer" -and $_.state -ceq 'completed' })
$peerNode = @($run.nodes | Where-Object { $_.nodeId -ceq "review_$peer" -and $_.state -ceq 'completed' })
if ($ownNode.Count -ne 1 -or $peerNode.Count -ne 1) { throw 'Both independent reviews must be complete.' }
$binding = $ownNode[0].execution.binding
if ($binding.provider -cne $provider -or $binding.sessionPreview -notmatch '^[0-9a-f]{8}$') {
    throw "The completed review does not identify its $provider session."
}
$matchingIds = @($ownNode[0].sessionIds | Where-Object {
    $_ -is [string] -and $_.StartsWith($binding.sessionPreview, [StringComparison]::OrdinalIgnoreCase)
})
$sessionId = [guid]::Empty
if ($matchingIds.Count -ne 1 -or ![guid]::TryParseExact($matchingIds[0], 'D', [ref]$sessionId)) {
    throw "The original $provider session ID is missing or ambiguous."
}

$peerReview = $null
$snapshots = Join-Path $artifactRoot '.archon\node-outcomes'
foreach ($snapshotFile in Get-ChildItem -LiteralPath $snapshots -File -Filter '*.json' | Sort-Object LastWriteTimeUtc -Descending) {
    $snapshot = Get-Content -LiteralPath $snapshotFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($snapshot.run_id -ne $runId) { continue }
    $peerReview = $snapshot.nodes | Where-Object {
        $_.node_id -ceq "review_$peer" -and $_.state -ceq 'completed' -and
        $null -ne $_.output -and $_.output.findings -is [array]
    } | Select-Object -First 1
    if ($peerReview) { break }
}
if (!$peerReview) { throw 'Archon did not record the peer reviewer findings.' }
$peerFindings = $peerReview.output.findings
$expectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($finding in $peerFindings) {
    if ([string]::IsNullOrWhiteSpace($finding.id) -or !$expectedIds.Add($finding.id)) {
        throw 'The peer review contains missing or duplicate finding IDs.'
    }
}

$findingsJson = ConvertTo-Json -InputObject $peerFindings -Depth 12 -Compress
$prompt = @"
Continue your independent review in this conversation. Both initial reviews are complete.
Use your earlier investigation and the other reviewer's findings below as a second point of view.
Assess each peer finding based on the code and version control evidence. Confirm, dispute, or
request more evidence. Explain the verdict and assign or adjust the priority where warranted,
using the priority scale from your initial review.
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
$timer = [Diagnostics.Stopwatch]::StartNew()
$cost = $null

if ($provider -ceq 'codex') {
    $codex = $env:CODEX_BIN_PATH
    if (!$codex) { $codex = (Get-Command codex.exe).Source }
    $schemaPath = Join-Path $artifactRoot ".archon\cross-check-$([guid]::NewGuid()).schema.json"
    [IO.File]::WriteAllText($schemaPath, $schema, $utf8)
    try {
        $arguments = @('--ask-for-approval', 'never', 'exec', '--skip-git-repo-check', '--json',
            '--output-schema', $schemaPath, '--model', $model, '-c', "model_reasoning_effort=$effort",
            'resume', $sessionId.ToString(), '-')
        $response = Invoke-ReviewerProcess $codex $arguments $prompt
    } finally {
        Remove-Item -LiteralPath $schemaPath -Force
    }
    $events = @(foreach ($line in $response -split '\r?\n') {
        if (![string]::IsNullOrWhiteSpace($line)) { ConvertFrom-Json -InputObject $line }
    })
    $threads = @($events | Where-Object type -ceq 'thread.started')
    $completed = $events | Where-Object type -ceq 'turn.completed' | Select-Object -Last 1
    if ($threads.Count -ne 1 -or $threads[0].thread_id -ne $sessionId -or !$completed) {
        throw 'Codex did not complete a turn in the exact reviewer chat.'
    }
    $lastMessage = $events | Where-Object { $_.type -ceq 'item.completed' -and $_.item.type -ceq 'agent_message' } |
        Select-Object -Last 1
    $result = $lastMessage.item.text | ConvertFrom-Json
    $usage = $completed.usage
    $tokens = @{
        input = $usage.input_tokens
        cacheRead = $usage.cached_input_tokens
        output = $usage.output_tokens
        cacheReadOutput = $usage.cached_output_tokens
    }
} else {
    $claude = $run.metadata.ai_configuration.assistants.claude.claudeBinaryPath
    if (!$claude) { $claude = (Get-Command claude.exe).Source }
    $arguments = @('--print', '--resume', $sessionId.ToString(), '--output-format', 'json', '--json-schema', $schema,
        '--model', $model, '--effort', $effort, '--setting-sources', 'project,user',
        '--permission-mode', 'bypassPermissions')
    $response = Invoke-ReviewerProcess $claude $arguments $prompt | ConvertFrom-Json
    if ($response.session_id -ne $sessionId -or $response.is_error -or $response.subtype -cne 'success') {
        throw 'Claude did not complete a turn in the exact reviewer chat.'
    }
    $result = $response.structured_output
    $usage = $response.usage
    $inputTotal = $null
    if ($null -ne $usage.input_tokens -and $null -ne $usage.cache_read_input_tokens -and
        $null -ne $usage.cache_creation_input_tokens) {
        $inputTotal = $usage.input_tokens + $usage.cache_read_input_tokens + $usage.cache_creation_input_tokens
    }
    $tokens = @{
        input = $inputTotal
        cacheRead = $usage.cache_read_input_tokens
        cacheWrite = $usage.cache_creation_input_tokens
        output = $usage.output_tokens
        cacheReadOutput = $usage.cache_read_output_tokens
    }
    $cost = $response.total_cost_usd
}
$timer.Stop()

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
        duration_ms = $timer.ElapsedMilliseconds
        tokens = $tokens
        cost_usd = $cost
    }
} -Depth 10 -Compress

# Archon snapshots a node's output only when a later node starts, and the transcript keeps only
# the tail of exec output. Save the full result so the run report can read it.
$resultDirectory = Join-Path $artifactRoot 'cross-checks'
[void][IO.Directory]::CreateDirectory($resultDirectory)
[IO.File]::WriteAllText((Join-Path $resultDirectory "cross_check_$Reviewer.json"), $json, $utf8)
$json
