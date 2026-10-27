<#
.SYNOPSIS
    T-501, step 2 of work plan section 5.2 (and its mirror in step 5): the guarded procedure that records the state of
    RequestManagement_Perf, and - only with a separate explicit approval - removes the five AddQueryIndexes indexes
    (`dotnet ef database update InitialCreate`) or puts them back (`dotnet ef database update`).

.DESCRIPTION
    The connection comes from ConnectionStrings__RequestManagement in the process environment, as in the other perf scripts; it is
    never printed. Actions:

      Snapshot       Checks every gate, then writes the recorded state to <SnapshotRoot>\RequestManagement_Perf.<Name>.txt
                     (default docs/perf/snapshots, outside docs/perf/results). SELECT statements and read-only dotnet ef
                     commands only. Refuses to replace an existing snapshot without -Overwrite.
      Check          Checks every gate and prints the approval codes. Writes nothing. Changes nothing.
      RemoveIndexes  Checks every gate against the snapshot and STOPS, printing the approval code. It changes the schema only
                     with -Execute -ConfirmDatabase RequestManagement_Perf -ApprovalCode <code printed for exactly this state>.
      RestoreIndexes The mirror image, from the state without the indexes back to the snapshot.

    Gates, in this order (any failure stops the run; nothing is ever repaired automatically):
      1  parameters and target, offline: the variable names exactly localhost,1433 / RequestManagement_Perf; the snapshot (when used)
         exists and is itself a valid, complete state;
      2  tools by full path (sqlcmd, docker, dotnet) and a Release/Debug EF build that is newer than its sources;
      3  guard-perf-target.ps1 -CheckServer: container running and healthy, port, database, T501_PERF_DB marker;
      4  dotnet ef dbcontext info: the context points at RequestManagement_Perf on localhost,1433 (not at the development database);
      5  the SQL that Entity Framework would run for the removal and for the restoration, generated offline (no connection), equals the
         expected text exactly;
      6  one SELECT batch: marker, ONLINE, not read-only, 100,000 rows, checksum -1953119262, distributions, id and date bounds,
         empty history, migration history, every index with every option, CHECK constraints, foreign key, no other session,
         and equality with the snapshot.
    A change also needs a person: after the approval code is accepted, a sentence naming the action, the database and the code must
    be typed at an interactive console. Redirected input or output (any non-interactive run) stops with HUMAN_CONFIRMATION_REQUIRED.
    For a change, gate 6 is repeated after the confirmation and immediately before the command, the command runs once, and
    after it the state is read again and must be exactly the expected one (the snapshot without the indexes, or the snapshot).

    Exit codes: 0 success (including "stopped before the change, as designed"), 1 stopped.

.PARAMETER Action
    Snapshot, Check, RemoveIndexes or RestoreIndexes. Required.
.PARAMETER Execute
    RemoveIndexes / RestoreIndexes only. Without it these actions stop after the gates and print the approval code.
.PARAMETER ConfirmDatabase
    Must be exactly RequestManagement_Perf, and only together with -Execute.
.PARAMETER ApprovalCode
    The code printed for the state that was verified. It changes with any difference in the state, the action or the snapshot.
.PARAMETER DryRun
    Print the plan and stop before any process, database or file is touched. Static checks (target, parameters, snapshot) still run.
#>
[CmdletBinding()]
param(
    [ValidateSet('Snapshot', 'Check', 'RemoveIndexes', 'RestoreIndexes')][string]$Action,
    [ValidatePattern('^[A-Za-z0-9._-]{1,40}$')][string]$SnapshotName = 'pre-step2',
    [string]$SnapshotRoot,
    [switch]$Execute,
    [string]$ConfirmDatabase,
    [string]$ApprovalCode,
    [switch]$Overwrite,
    [switch]$DryRun,
    [switch]$KeepWorkOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PerfTool = 'SET-INDEX-STATE'
. (Join-Path $PSScriptRoot 'perf-common.ps1')
. (Join-Path $PSScriptRoot 'perf-schema-step.ps1')
$script:PerfKeepOnFailure = [bool]$KeepWorkOnFailure
# An unexpected error (not a Stop-Run) still removes the temporary folder.
trap { Invoke-PerfFailureCleanup; break }

$backendDir = Join-Path $script:PerfRepo 'backend'
$efDll = Join-Path $backendDir 'src\RequestManagement.Infrastructure\bin\Debug\net10.0\RequestManagement.Infrastructure.dll'
$efProjectArguments = @('--project', 'src/RequestManagement.Infrastructure', '--startup-project', 'src/RequestManagement.Infrastructure', '--no-build', '--no-color')

# ---- 1. parameters, target, snapshot: offline ---------------------------------------------------------------------------------------
if (-not $Action) { Stop-Run 'ACTION_MISSING' '-Action Snapshot|Check|RemoveIndexes|RestoreIndexes is required.' }
$isChange = $Action -in @('RemoveIndexes', 'RestoreIndexes')
if ($Execute -and -not $isChange) { Stop-Run 'EXECUTE_NOT_ALLOWED' "-Execute only belongs to RemoveIndexes and RestoreIndexes; '$Action' never changes the schema." }
if (($ConfirmDatabase -or $ApprovalCode) -and -not $Execute) { Stop-Run 'APPROVAL_WITHOUT_EXECUTE' '-ConfirmDatabase and -ApprovalCode are only accepted together with -Execute.' }
if ($Overwrite -and $Action -ne 'Snapshot') { Stop-Run 'OVERWRITE_NOT_ALLOWED' '-Overwrite only belongs to -Action Snapshot.' }
if ($Execute) {
    if ($ConfirmDatabase -cne $script:PerfDatabase) { Stop-Run 'CONFIRM_MISSING' "-Execute needs -ConfirmDatabase $($script:PerfDatabase)." }
    if ([string]::IsNullOrWhiteSpace($ApprovalCode)) { Stop-Run 'APPROVAL_REQUIRED' '-Execute needs -ApprovalCode, the code printed for the verified state by a run without -Execute.' }
    if ($ApprovalCode -cnotmatch '^[0-9A-F]{12}$') { Stop-Run 'APPROVAL_CODE_MISMATCH' 'The approval code is 12 upper-case hexadecimal characters.' }
}
$builder = Get-PerfTarget

if (-not $SnapshotRoot) { $SnapshotRoot = Join-Path $PSScriptRoot 'snapshots' }
$snapshotRootFull = Resolve-PerfResultsRoot $SnapshotRoot
if (Test-PerfDefaultResults $snapshotRootFull) { Stop-Run 'SNAPSHOT_ROOT_IS_RESULTS' 'The snapshot must not be written into docs/perf/results.' }
$snapshotName = "RequestManagement_Perf.$SnapshotName.txt"
$snapshotFile = Join-Path $snapshotRootFull $snapshotName
$snapshotExists = Test-Path -LiteralPath $snapshotFile
if ($Action -eq 'Snapshot' -and $snapshotExists -and -not $Overwrite) {
    Stop-Run 'RESULTS_EXIST' "The snapshot '$snapshotName' already exists and was not replaced. Use -Overwrite only if replacing it is intended."
}
$snapshot = $null
$snapshotSha = $null
if ($Action -ne 'Snapshot') {
    if ($snapshotExists) {
        try { $snapshot = Read-StepSnapshot $snapshotFile } catch { Stop-Run 'SNAPSHOT_INVALID' "The snapshot '$snapshotName' cannot be read." }
        $problems = @(Get-StepGateFailures $snapshot 'WithIndexes')
        if ($problems.Count -gt 0) { Stop-Run 'SNAPSHOT_INVALID' "The snapshot '$snapshotName' is not a valid recorded state: $($problems[0])" }
        $snapshotSha = Get-StepFactsSha256 $snapshot
        if ($snapshotSha -cne $script:StepOriginalSnapshotFactsSha256) {
            Stop-Run 'SNAPSHOT_NOT_ORIGINAL' "The snapshot '$snapshotName' is a valid state but not the recorded original (facts sha256 $($snapshotSha.Substring(0, 16))..., expected $($script:StepOriginalSnapshotFactsSha256.Substring(0, 16))...); it was not used."
        }
    }
    elseif ($isChange) { Stop-Run 'SNAPSHOT_MISSING' "A change needs the snapshot '$snapshotName' (take it with -Action Snapshot first)." }
}

# ---- 2. dry run ---------------------------------------------------------------------------------------------------------------------------
if ($DryRun) {
    Write-Host "SET-INDEX-STATE DRY RUN - action '$Action'. Nothing below is executed: no process is started, no database is contacted, no file or folder is written."
    Write-Host "Target (static checks passed): server '$($builder.DataSource)', database '$($builder.InitialCatalog)' (from $($script:PerfEnvName))."
    Write-Host "Snapshot: $snapshotFile ($(if ($snapshotExists) { 'exists' } else { 'does not exist' }))$(if ($snapshot) { '; read and valid' })"
    Write-Host 'Gates, in this order; any failure stops the run and nothing is repaired automatically:'
    Write-Host 'PLAN GATE: 2 tools (sqlcmd, docker, dotnet) by full path; the EF build is newer than its sources'
    Write-Host 'PLAN GATE: 3 guard-perf-target.ps1 -CheckServer (container, server, database, T501_PERF_DB marker)'
    Write-Host 'PLAN GATE: 4 dotnet ef dbcontext info names RequestManagement_Perf on localhost,1433'
    Write-Host 'PLAN GATE: 5 the SQL of the removal and of the restoration (dotnet ef migrations script, no connection) equals the expected text'
    Write-Host "PLAN GATE: 6 one SELECT batch: marker, rows 100000, checksum $($script:StepExpectedChecksum), distributions, bounds, migrations, indexes with all options, constraints, foreign key, no other sessions$(if ($Action -ne 'Snapshot') { ', equality with the snapshot' })"
    switch ($Action) {
        'Snapshot' { Write-Host "Then: write the snapshot to $snapshotFile (create-only$(if ($Overwrite) { '; -Overwrite given' }))." }
        'Check' { Write-Host 'Then: print the approval codes. Nothing is written or changed.' }
        default {
            if ($Execute) {
                Write-Host "With -Execute: the code is compared with the code of the verified state; a person must then type a confirmation sentence at an interactive console (redirected input or output stops the run); then the gates are read again, 'dotnet ef database update$(if ($Action -eq 'RemoveIndexes') { ' InitialCreate' })' would run once, and the state afterwards must be exactly the expected one."
            }
            else { Write-Host 'Without -Execute: stop after the gates and print the approval code. The schema is not changed.' }
        }
    }
    Write-Host 'DRY RUN OK - nothing was executed.' -ForegroundColor Green
    exit 0
}

# ---- 3. real run: tools, build, guard, EF context, EF SQL ------------------------------------------------------------------------------------
foreach ($tool in @('sqlcmd', 'docker', 'dotnet')) { [void](Resolve-PerfTool $tool) }
if (-not (Test-Path -LiteralPath $efDll)) { Stop-Run 'EF_NOT_BUILT' "The EF design-time build is missing ($efDll). Build the Infrastructure project first; this script never builds." }
$efDllTime = (Get-Item -LiteralPath $efDll).LastWriteTimeUtc
$newerSources = @(
    foreach ($project in @('RequestManagement.Infrastructure', 'RequestManagement.Core')) {
        Get-ChildItem -LiteralPath (Join-Path $backendDir "src\$project") -Recurse -File -Include *.cs, *.csproj |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.LastWriteTimeUtc -gt $efDllTime }
    }
)
if ($newerSources.Count -gt 0) { Stop-Run 'EF_BUILD_STALE' "The EF build is older than $($newerSources.Count) source file(s), for example '$($newerSources[0].Name)'. Rebuild it first." }
Write-Host 'Gate 2 ok: tools resolved by full path; the EF build is newer than its sources.'

Invoke-ServerGuard $builder
Write-Host 'Gate 3 ok: the guard confirmed the container, server, database and marker.'

$work = New-PerfWorkDir

$context = Invoke-ChildProcess -FileName 'dotnet' -WorkingDirectory $backendDir -TimeoutSeconds 180 -Arguments (@('ef', 'dbcontext', 'info') + $efProjectArguments)
$contextText = Hide-Secrets ($context.Stdout + "`n" + $context.Stderr) $builder.Password
$contextDatabase = if ($contextText -match '(?m)^Database name:\s*(.+?)\s*$') { $matches[1] } else { $null }
$contextServer = if ($contextText -match '(?m)^Data source:\s*(.+?)\s*$') { $matches[1] } else { $null }
if ($context.ExitCode -ne 0 -or $contextDatabase -cne $script:PerfDatabase -or $contextServer -cne $builder.DataSource) {
    Stop-Run 'EF_TARGET_MISMATCH' "dotnet ef dbcontext info reported database '$contextDatabase' on '$contextServer' (exit $($context.ExitCode)); the context does not point at the performance database."
}
Write-Host "Gate 4 ok: dotnet ef dbcontext info reports '$contextDatabase' on '$contextServer'."

foreach ($direction in @(@('Remove', 'AddQueryIndexes', 'InitialCreate'), @('Restore', 'InitialCreate', 'AddQueryIndexes'))) {
    # The connection variable is removed for this child, so no connection can be made: the script is generated from the migrations.
    $scriptRun = Invoke-ChildProcess -FileName 'dotnet' -WorkingDirectory $backendDir -TimeoutSeconds 180 -ChildEnv @{ 'ConnectionStrings__RequestManagement' = $null } `
        -Arguments (@('ef', 'migrations', 'script', $direction[1], $direction[2]) + $efProjectArguments)
    if ($scriptRun.ExitCode -ne 0 -or -not (Test-EfScriptMatches $direction[0] $scriptRun.Stdout)) {
        Stop-Run 'EF_SQL_MISMATCH' "The SQL that Entity Framework generates for the $($direction[0].ToLowerInvariant()) ($($direction[1]) to $($direction[2])) is not the expected text; nothing was run."
    }
}
Write-Host 'Gate 5 ok: the removal and restoration SQL, generated offline, equals the expected text.'

function Get-LiveState {
    $run = Invoke-PerfSqlcmd -Builder $builder -Kind SchemaState -WorkDir $work
    ConvertFrom-SchemaState $run.Stdout
}

function Stop-OnGateFailure($State, [string]$Kind, [string]$Label) {
    $failures = @(Get-StepGateFailures $State $Kind $snapshot)
    if ($failures.Count -gt 0) {
        $where = if ($snapshot) { " $(Format-StepClassification (Get-StepStateClassification $State $snapshot))" } else { '' }
        Stop-Run 'GATE_FAILED' "$Label - the state is not '$Kind': $(@($failures | Select-Object -First 4) -join ' | ')$(if ($failures.Count -gt 4) { " | (+$($failures.Count - 4) more)" }). Nothing was changed by this run and nothing will be repaired automatically.$where"
    }
}

$state1 = Get-LiveState

# ---- ACTION: Snapshot --------------------------------------------------------------------------------------------------------------------
if ($Action -eq 'Snapshot') {
    Stop-OnGateFailure $state1 'WithIndexes' 'Gate 6'
    Write-Host 'Gate 6 ok: the database is in the expected state WithIndexes.'
    $staging = Join-Path $work 'out'
    New-Item -ItemType Directory -Path $staging | Out-Null
    Write-Utf8NoBom (Join-Path $staging $snapshotName) (Format-StepSnapshot $state1 (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') $builder.DataSource)
    Publish-PerfOutput $staging $snapshotRootFull @($snapshotName) ([bool]$Overwrite)
    [void](Remove-PerfWorkDir $work)
    Write-Host "SNAPSHOT OK - written to $snapshotFile (facts sha256 $((Get-StepFactsSha256 $state1).Substring(0, 16))...). The database was only read." -ForegroundColor Green
    exit 0
}

# ---- ACTION: Check -------------------------------------------------------------------------------------------------------------------------
if ($Action -eq 'Check') {
    $withFailures = @(Get-StepGateFailures $state1 'WithIndexes' $snapshot)
    $withoutFailures = @(Get-StepGateFailures $state1 'WithoutIndexes' $snapshot)
    if ($withFailures.Count -eq 0) {
        Write-Host 'Gate 6 ok: the database is in the expected state WithIndexes.'
        if ($snapshot) { Write-Host "Approval code for -Action RemoveIndexes -Execute: $(Get-StepApprovalCode 'RemoveIndexes' $state1 $snapshotSha)" }
        else { Write-Host 'No snapshot yet: take one with -Action Snapshot; a change needs it.' }
    }
    elseif ($withoutFailures.Count -eq 0 -and $snapshot) {
        Write-Host 'Gate 6 ok: the database is in the expected state WithoutIndexes (the snapshot without the five indexes).'
        Write-Host "Approval code for -Action RestoreIndexes -Execute: $(Get-StepApprovalCode 'RestoreIndexes' $state1 $snapshotSha)"
    }
    else {
        $where = if ($snapshot) { " $(Format-StepClassification (Get-StepStateClassification $state1 $snapshot))" } else { '' }
        Stop-Run 'GATE_FAILED' "The state is neither WithIndexes ($(@($withFailures | Select-Object -First 3) -join ' | ')) nor WithoutIndexes$(if (-not $snapshot) { ' (no snapshot to compare with)' } else { " ($(@($withoutFailures | Select-Object -First 2) -join ' | '))" }). Nothing was changed by this run.$where"
    }
    [void](Remove-PerfWorkDir $work)
    Write-Host 'CHECK OK - nothing was changed; the codes above belong to exactly this verified state.' -ForegroundColor Green
    exit 0
}

# ---- ACTION: RemoveIndexes / RestoreIndexes ------------------------------------------------------------------------------------
function Invoke-StepChange([string]$ChangeAction, [string]$FromKind, [string]$ToKind) {
    Stop-OnGateFailure $state1 $FromKind 'Gate 6'
    Write-Host "Gate 6 ok: the database is in the expected state $FromKind."
    $code = Get-StepApprovalCode $ChangeAction $state1 $snapshotSha
    if (-not $Execute) {
        Write-Host "STOPPED BEFORE THE CHANGE, as designed: $ChangeAction is a schema change and needs a separate explicit approval. Nothing was changed."
        Write-Host "Approval code for exactly this verified state: $code"
        Write-Host "To proceed (only after approval): powershell.exe -File docs\perf\set-index-state.ps1 -Action $ChangeAction -Execute -ConfirmDatabase $($script:PerfDatabase) -ApprovalCode $code"
        [void](Remove-PerfWorkDir $work)
        exit 0
    }
    Grant-SchemaChangeApproval $ChangeAction $ConfirmDatabase $ApprovalCode $code
    Write-Host 'Approval code accepted for this action and this verified state.'
    Confirm-StepByHuman $ChangeAction $code ([Console]::IsInputRedirected) ([Console]::IsOutputRedirected) { [Console]::In.ReadLine() }
    Write-Host 'Confirmation sentence accepted.'
    $recheck = Get-LiveState
    Stop-OnGateFailure $recheck $FromKind 'Gate 6 (again, immediately before the command)'
    if ((Get-StepApprovalCode $ChangeAction $recheck $snapshotSha) -cne $code) { Stop-Run 'STATE_CHANGED' 'The state changed after the approval code was computed; nothing was run.' }
    Write-Host "Running the one schema-changing command for $ChangeAction ..."
    $update = Invoke-EfDatabaseUpdate $ChangeAction $backendDir
    if ($update.ExitCode -ne 0) {
        Stop-Run 'EF_UPDATE_FAILED' "dotnet ef database update exited with $($update.ExitCode)$(if ($update.TimedOut) { ' (timed out; the process tree was stopped)' }). The state was NOT read after the failure and nothing is repaired automatically. Do not retry. First wait until no dotnet/sqlcmd process of this run and no other session remains, then run -Action Check: it classifies the state (see SCHEMA_STEP.md, Recovery). $($update.Text.Substring(0, [Math]::Min(400, $update.Text.Length)))"
    }
    $after = Get-LiveState
    $postCheckStop = Get-StepPostCheckStop $after $ToKind $snapshot
    if ($postCheckStop) { Stop-Run 'POST_CHECK_FAILED' $postCheckStop }
    [void](Remove-PerfWorkDir $work)
    Write-Host "CHANGE OK - $ChangeAction done; the state now equals '$ToKind' (the data, checksum, marker and history are as expected)." -ForegroundColor Green
    exit 0
}

if ($Action -eq 'RemoveIndexes') { Invoke-StepChange 'RemoveIndexes' 'WithIndexes' 'WithoutIndexes' }
if ($Action -eq 'RestoreIndexes') { Invoke-StepChange 'RestoreIndexes' 'WithoutIndexes' 'WithIndexes' }
