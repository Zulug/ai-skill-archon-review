# Shared helpers for resuming a provider session that an Archon run started. Dot-source this
# file. The cross-check and implementer-continuation runners send turns with it, and the run
# report and launcher use it to find executables and session IDs. Provider details live only
# here, so a different provider in models.yaml needs no change in the callers.

$script:ArchonUtf8 = [Text.UTF8Encoding]::new($false)

function Get-ArchonExecutable {
    $command = Get-Command archon.exe -ErrorAction SilentlyContinue
    if ($command) { $command.Source } else { Join-Path $env:USERPROFILE '.archon\bin\archon.exe' }
}

function Get-CodexExecutable {
    if ($env:CODEX_BIN_PATH) { return $env:CODEX_BIN_PATH }
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $app = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue
        if ($app) { return Join-Path $app.InstallLocation 'app\resources\codex.exe' }
    }
}

# Returns $null when Archon has no record of the run for this workspace.
function Get-ArchonRunRecord([guid]$RunId, [string]$Workspace) {
    $archon = Get-ArchonExecutable
    # Windows PowerShell turns redirected native stderr into errors under 'Stop'.
    $runJson = & { $ErrorActionPreference = 'Continue'; & $archon workflow get $RunId.ToString() --verbose --json --cwd $Workspace 2>$null }
    if ($LASTEXITCODE -ne 0 -or !$runJson) { return $null }
    $run = ($runJson -join [Environment]::NewLine) | ConvertFrom-Json
    if ($run.id -ne $RunId -or $run.working_path -ine $Workspace) { return $null }
    $run
}

# Transcripts and bindings keep only a session ID prefix; the run record node has full IDs.
# Returns $null when the ID is missing or ambiguous.
function Find-ArchonSessionId($RunNode, $Binding) {
    if (!$Binding.sessionPreview) { return $null }
    $ids = @($RunNode.sessionIds | Where-Object {
        $_ -is [string] -and $_.StartsWith($Binding.sessionPreview, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($ids.Count -eq 1) { $ids[0] }
}

# Use the same Windows argument quoting with Windows PowerShell and PowerShell 7.
# The prompt goes over UTF-8 stdin, so its text cannot become command arguments.
function Invoke-ArchonProviderProcess([string]$Provider, [string]$Executable, [string[]]$Arguments,
    [string]$Prompt, [string]$Workspace) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $Workspace
    $info.Arguments = ($Arguments | ForEach-Object {
        '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:ArchonUtf8
    $info.StandardErrorEncoding = $script:ArchonUtf8
    if ($Provider -ceq 'claude') { $info.EnvironmentVariables.Remove('CLAUDECODE') }

    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $bytes = $script:ArchonUtf8.GetBytes($Prompt)
        $stdin = $process.StandardInput.BaseStream
        try {
            $stdin.Write($bytes, 0, $bytes.Length)
        } finally {
            $stdin.Close()
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "$Provider failed to resume its original session (exit $($process.ExitCode)). $($stderr.GetAwaiter().GetResult().Trim())"
        }
        $stdout.GetAwaiter().GetResult()
    } finally {
        $process.Dispose()
    }
}

# Sends one turn to an existing session and returns its structured result with telemetry.
# Tokens use Archon's field names. Codex reports session-to-date tokens on resume, and Claude
# reports session-to-date cost; callers that need one turn's usage subtract the earlier turns.
# -WriteAccess gives a Codex turn the full access Archon gives its agent nodes; Claude turns
# always run with bypassed permissions, as Archon runs them.
function Invoke-ArchonSessionTurn {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][guid]$SessionId,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Schema,
        # Codex reads its output schema from a file; it is written here and removed afterwards.
        [Parameter(Mandatory)][string]$SchemaDirectory,
        [string]$ClaudeExecutable,
        [switch]$WriteAccess
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $cost = $null
    if ($Provider -ceq 'codex') {
        $codex = Get-CodexExecutable
        if (!$codex) { throw 'Codex is not installed.' }
        [void][IO.Directory]::CreateDirectory($SchemaDirectory)
        $schemaPath = Join-Path $SchemaDirectory "session-turn-$([guid]::NewGuid()).schema.json"
        [IO.File]::WriteAllText($schemaPath, $Schema, $script:ArchonUtf8)
        try {
            $arguments = @('--ask-for-approval', 'never', 'exec', '--skip-git-repo-check', '--json',
                '--output-schema', $schemaPath, '--model', $Model, '-c', "model_reasoning_effort=$Effort")
            if ($WriteAccess) { $arguments += @('-c', 'sandbox_mode="danger-full-access"') }
            $arguments += @('resume', $SessionId.ToString(), '-')
            $response = Invoke-ArchonProviderProcess $Provider $codex $arguments $Prompt $Workspace
        } finally {
            Remove-Item -LiteralPath $schemaPath -Force
        }
        $events = @(foreach ($line in $response -split '\r?\n') {
            if (![string]::IsNullOrWhiteSpace($line)) { ConvertFrom-Json -InputObject $line }
        })
        $threads = @($events | Where-Object type -ceq 'thread.started')
        $completed = $events | Where-Object type -ceq 'turn.completed' | Select-Object -Last 1
        if ($threads.Count -ne 1 -or $threads[0].thread_id -ne $SessionId -or !$completed) {
            throw "Codex did not complete a turn in the exact session. SessionId=$SessionId"
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
    } elseif ($Provider -ceq 'claude') {
        $claude = $ClaudeExecutable
        if (!$claude) { $claude = (Get-Command claude.exe).Source }
        $arguments = @('--print', '--resume', $SessionId.ToString(), '--output-format', 'json', '--json-schema', $Schema,
            '--model', $Model, '--effort', $Effort, '--setting-sources', 'project,user',
            '--permission-mode', 'bypassPermissions')
        $response = Invoke-ArchonProviderProcess $Provider $claude $arguments $Prompt $Workspace | ConvertFrom-Json
        if ($response.session_id -ne $SessionId -or $response.is_error -or $response.subtype -cne 'success') {
            throw "Claude did not complete a turn in the exact session. SessionId=$SessionId"
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
    } else {
        throw "Resuming a session is not supported for this provider. Provider=$Provider"
    }
    $timer.Stop()

    [pscustomobject]@{
        Result = $result
        Tokens = $tokens
        CostUsd = $cost
        DurationMs = $timer.ElapsedMilliseconds
    }
}
