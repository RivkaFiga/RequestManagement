<#
.SYNOPSIS
    T-501: the only sanctioned way to run the Seeder against the dedicated performance database.

.DESCRIPTION
    The caller must define ConnectionStrings__RequestManagement in the process environment. Nothing is read from
    user-secrets, .env or any default, and the connection string is never printed.

    Mode Preflight (default, read-only; the Seeder is NOT started):
      P1  the variable is set, and targets exactly localhost,1433 / 127.0.0.1,1433 and database RequestManagement_Perf
      P2  guard-perf-target.ps1 -CheckServer, as a separate process, passes
      P3  an empty temporary folder is prepared to replace APPDATA for the child processes
      P4  the child process really receives the variables (checked from inside a child; only booleans are printed)
      P5  user-secrets are really not reachable from a child that runs with the replaced APPDATA
      P6  `dotnet ef dbcontext info`, run with the same variables and isolation, reports RequestManagement_Perf on localhost,1433
      P7  the Release Seeder build exists
      P8  the Seeder's own guard is active in that build: it refuses (exit 3, before any connection) a wrong
          --expect-database, and it refuses when the variable is missing even though user-secrets are reachable

    Mode Execute (needs -ConfirmDatabase RequestManagement_Perf): CREATES the database; it never resets one.
      The database must not exist (the guard says so and the Seeder checks again). Runs P1-P8, then
      `Seeder --create-new --expect-server ... --expect-database ... --count N` with DOTNET_ENVIRONMENT=Development
      and the isolated APPDATA set ONLY for that child process, then writes the T501_PERF_DB marker and re-runs the guard.
      Resetting an existing database is deliberately not offered here; it needs separate explicit approval.

    Every stop prints `RUN-SEEDER: STOP [CODE] ...` and exits 1. Before the Seeder is launched, nothing has been
    written to any database.
#>
[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Execute')][string]$Mode = 'Preflight',
    [string]$ConfirmDatabase,
    [int]$Count = 100000,
    [int]$Seed = 20261020,
    [int]$BatchSize = 10000,
    [string]$Container = 'request-management-sql',
    [string]$TranscriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$guardPath = Join-Path $PSScriptRoot 'guard-perf-target.ps1'
$seederDll = Join-Path $repo 'backend\src\RequestManagement.Seeder\bin\Release\net10.0\RequestManagement.Seeder.dll'
$seederProject = Join-Path $repo 'backend\src\RequestManagement.Seeder\RequestManagement.Seeder.csproj'
$infraProject = Join-Path $repo 'backend\src\RequestManagement.Infrastructure\RequestManagement.Infrastructure.csproj'
$envName = 'ConnectionStrings__RequestManagement'
$expectedDatabase = 'RequestManagement_Perf'

. $guardPath   # defines Get-PerfTargetFailures only (the guard's main block is skipped when dot-sourced)

function Stop-Run([string]$Code, [string]$Message) {
    Write-Host "RUN-SEEDER: STOP [$Code] $Message" -ForegroundColor Red
    exit 1
}

function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
}

function Hide-Secrets([string]$Text, [string]$Password) {
    $lines = $Text -split "`r?`n" | Where-Object { $_ -notmatch '(?i)password|pwd=' }
    $joined = $lines -join "`n"
    if ($Password) { $joined = $joined.Replace($Password, '***') }
    $joined
}

# Starts a child with an explicit environment. $ChildEnv entries override the inherited ones; a $null value removes the variable.
function Invoke-ChildProcess {
    param([string]$FileName, [string[]]$Arguments, [hashtable]$ChildEnv = @{}, [string]$WorkingDirectory = $repo)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = (($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($key in $ChildEnv.Keys) {
        if ($null -eq $ChildEnv[$key]) { [void]$psi.EnvironmentVariables.Remove($key) }
        else { $psi.EnvironmentVariables[$key] = [string]$ChildEnv[$key] }
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderrTask.Result }
}

# ---- Execute needs an explicit confirmation of the database name -------------------------------------------------
if ($Mode -eq 'Execute' -and $ConfirmDatabase -cne $expectedDatabase) {
    Stop-Run 'CONFIRM_MISSING' "Execute mode needs -ConfirmDatabase $expectedDatabase."
}

# ---- P1: the variable is set explicitly and points at exactly the Perf database ------------------------------------
$connectionString = [Environment]::GetEnvironmentVariable($envName, 'Process')
if ([string]::IsNullOrWhiteSpace($connectionString)) {
    Stop-Run 'ENV_MISSING' "$envName is not set in the process environment. The Seeder would fall back to user-secrets."
}
$targetFailures = @(Get-PerfTargetFailures -ConnectionString $connectionString)
if ($targetFailures.Count -gt 0) {
    Stop-Run 'TARGET_MISMATCH' ($targetFailures -join ' ')
}
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connectionString)
Write-Host "P1 ok: $envName is set; server '$($builder.DataSource)', database '$($builder.InitialCatalog)' (exact match)."

# ---- P2: the guard, as a separate process ---------------------------------------------------------------------------
$guardRun = Invoke-ChildProcess -FileName 'powershell.exe' `
    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guardPath, '-CheckServer', '-Container', $Container)
Write-Host ((Hide-Secrets ($guardRun.Stdout + $guardRun.Stderr) $builder.Password).Trim())
if ($guardRun.ExitCode -ne 0) {
    Stop-Run 'GUARD_FAILED' "guard-perf-target.ps1 -CheckServer exited with $($guardRun.ExitCode)."
}
Write-Host 'P2 ok: guard passed in a separate process.'
$databaseAbsent = $guardRun.Stdout -match 'does not exist'
if ($Mode -eq 'Execute' -and -not $databaseAbsent) {
    Stop-Run 'DB_EXISTS' "'$expectedDatabase' already exists. Execute only creates; resetting needs separate explicit approval."
}

# ---- P3: an empty folder that replaces APPDATA for the children ------------------------------------------------------
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$isolatedAppData = Join-Path $tempRoot ('t501-appdata-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $isolatedAppData | Out-Null
try {
    if (@(Get-ChildItem -Force $isolatedAppData).Count -ne 0) { Stop-Run 'ISOLATION_FAILED' 'The temporary APPDATA folder is not empty.' }
    Write-Host 'P3 ok: empty temporary APPDATA folder created.'

    $childEnv = @{
        'DOTNET_ENVIRONMENT'      = 'Development'
        'APPDATA'                 = $isolatedAppData
        $envName                  = $connectionString
        'T501_EXPECT_APPDATA'     = $isolatedAppData
        'T501_EXPECT_CS_SHA256'   = (Get-Sha256Hex $connectionString)
    }
    $parentHasDevEnvironment = -not [string]::IsNullOrEmpty($env:DOTNET_ENVIRONMENT)

    # ---- P4: the variables really reach a child process ----------------------------------------------------------------
    $probe = @'
$cs = [Environment]::GetEnvironmentVariable('ConnectionStrings__RequestManagement', 'Process')
$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($cs)
$sha = [System.Security.Cryptography.SHA256]::Create()
$h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($cs)))).Replace('-', '')
'DOTNET_ENVIRONMENT=' + $env:DOTNET_ENVIRONMENT
'APPDATA_ISOLATED=' + ($env:APPDATA -eq $env:T501_EXPECT_APPDATA)
'CONNECTION_STRING_SHA256_MATCH=' + ($h -eq $env:T501_EXPECT_CS_SHA256)
'SERVER=' + $b.DataSource
'DATABASE=' + $b.InitialCatalog
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $probeRun = Invoke-ChildProcess -FileName 'powershell.exe' -Arguments @('-NoProfile', '-EncodedCommand', $encoded) -ChildEnv $childEnv
    $facts = @{}
    foreach ($line in ($probeRun.Stdout -split "`r?`n")) { if ($line -match '^([A-Z0-9_]+)=(.*)$') { $facts[$matches[1]] = $matches[2].Trim() } }
    $passed = ($probeRun.ExitCode -eq 0) -and
        ($facts['DOTNET_ENVIRONMENT'] -ceq 'Development') -and
        ($facts['APPDATA_ISOLATED'] -ceq 'True') -and
        ($facts['CONNECTION_STRING_SHA256_MATCH'] -ceq 'True') -and
        ($facts['SERVER'] -ceq $builder.DataSource) -and
        ($facts['DATABASE'] -ceq $expectedDatabase)
    if (-not $passed) { Stop-Run 'ENV_NOT_PASSED' 'The child process did not receive the expected variables.' }
    Write-Host ("P4 ok: the child received DOTNET_ENVIRONMENT=Development, the isolated APPDATA, and the identical connection string (SHA-256 match); " +
        "server '$($facts['SERVER'])', database '$($facts['DATABASE'])'. This parent process has DOTNET_ENVIRONMENT set: $parentHasDevEnvironment.")

    # ---- P5: user-secrets are not reachable from an isolated child --------------------------------------------------------
    $control = Invoke-ChildProcess -FileName 'dotnet' -Arguments @('user-secrets', 'list', '--project', $seederProject) `
        -ChildEnv @{ 'T501_EXPECT_APPDATA' = $null; 'T501_EXPECT_CS_SHA256' = $null }
    $controlCount = @(($control.Stdout -split "`r?`n") | Where-Object { $_ -match '^\S.* = ' }).Count
    $isolated = Invoke-ChildProcess -FileName 'dotnet' -Arguments @('user-secrets', 'list', '--project', $seederProject) -ChildEnv $childEnv
    $isolatedCount = @(($isolated.Stdout -split "`r?`n") | Where-Object { $_ -match '^\S.* = ' }).Count
    $saysNone = $isolated.Stdout -match 'No secrets configured'
    if ($isolated.ExitCode -ne 0 -or $isolatedCount -ne 0 -or -not $saysNone) {
        Stop-Run 'ISOLATION_FAILED' "user-secrets are still reachable or could not be checked (isolated exit $($isolated.ExitCode), visible secrets $isolatedCount)."
    }
    if ($control.ExitCode -ne 0) {
        Stop-Run 'ISOLATION_UNVERIFIED' 'The un-isolated control listing failed, so the isolated result proves nothing.'
    }
    Write-Host ("P5 ok: without isolation $controlCount user-secret(s) are visible to the Seeder project; with the isolated APPDATA: 0 ('No secrets configured'). " +
        'Values were not printed.')

    # ---- P6: dotnet ef dbcontext info with the same variables and isolation -----------------------------------------------
    $efRun = Invoke-ChildProcess -FileName 'dotnet' -ChildEnv $childEnv `
        -Arguments @('ef', 'dbcontext', 'info', '--project', $infraProject, '--no-build', '--no-color')
    $efText = Hide-Secrets ($efRun.Stdout + "`n" + $efRun.Stderr) $builder.Password
    $efDatabase = if ($efText -match '(?m)^Database name:\s*(.+?)\s*$') { $matches[1] } else { $null }
    $efServer = if ($efText -match '(?m)^Data source:\s*(.+?)\s*$') { $matches[1] } else { $null }
    if ($efRun.ExitCode -ne 0 -or $efDatabase -cne $expectedDatabase -or $efServer -cne $builder.DataSource) {
        Stop-Run 'EF_TARGET_MISMATCH' "dotnet ef dbcontext info reported database '$efDatabase' on '$efServer' (exit $($efRun.ExitCode))."
    }
    Write-Host "P6 ok: dotnet ef dbcontext info reports database '$efDatabase' on '$efServer'."

    # ---- P7: the Release Seeder build -------------------------------------------------------------------------------------
    if (-not (Test-Path $seederDll)) { Stop-Run 'SEEDER_NOT_BUILT' "Build the Seeder first: dotnet build backend\src\RequestManagement.Seeder -c Release ($seederDll is missing)." }
    $dllHash = (Get-FileHash -Algorithm SHA256 $seederDll).Hash
    Write-Host "P7 ok: Seeder build found, SHA-256 $dllHash."

    # ---- P8: the Seeder's own guard, exercised in its refusal paths (both stop before any connection is opened) ----------
    $wrongDatabase = Invoke-ChildProcess -FileName 'dotnet' -ChildEnv $childEnv -Arguments @(
        $seederDll, '--create-new', '--expect-server', $builder.DataSource, '--expect-database', ($expectedDatabase + '_selfcheck'))
    if ($wrongDatabase.ExitCode -ne 3 -or ($wrongDatabase.Stderr + $wrongDatabase.Stdout) -notmatch 'expected exactly') {
        Stop-Run 'SEEDER_GUARD_MISSING' "The Seeder did not refuse a wrong --expect-database (exit $($wrongDatabase.ExitCode)). Is the build current?"
    }
    $withoutVariable = @{} + $childEnv
    $withoutVariable[$envName] = $null
    [void]$withoutVariable.Remove('APPDATA')   # real APPDATA: user-secrets ARE reachable here, on purpose
    $withoutVariable['DOTNET_ENVIRONMENT'] = 'Development'
    $missingVariable = Invoke-ChildProcess -FileName 'dotnet' -ChildEnv $withoutVariable -Arguments @(
        $seederDll, '--create-new', '--expect-server', $builder.DataSource, '--expect-database', $expectedDatabase)
    $missingText = $missingVariable.Stderr + $missingVariable.Stdout
    $refusedForMissingVariable = ($missingVariable.ExitCode -eq 3 -and $missingText -match 'not set in the process environment') -or
        ($missingVariable.ExitCode -eq 2 -and $missingText -match 'not found')
    if (-not $refusedForMissingVariable) {
        Stop-Run 'SEEDER_GUARD_MISSING' "The Seeder did not refuse to run without the environment variable (exit $($missingVariable.ExitCode))."
    }
    Write-Host ('P8 ok: the Seeder itself refused a wrong --expect-database (exit 3) and refused to run without the environment ' +
        "variable while user-secrets were reachable (exit $($missingVariable.ExitCode)); no connection was opened.")

    if ($Mode -eq 'Preflight') {
        Write-Host 'PREFLIGHT OK - all checks passed. The Seeder was NOT started and no database was created or changed.' -ForegroundColor Green
        exit 0
    }

    # ---- Execute -----------------------------------------------------------------------------------------------------------
    Write-Host "Starting the Seeder: --create-new --count $Count --seed $Seed --batch-size $BatchSize (database '$expectedDatabase', isolated APPDATA, DOTNET_ENVIRONMENT=Development for the child only)."
    $seedRun = Invoke-ChildProcess -FileName 'dotnet' -ChildEnv $childEnv -Arguments @(
        $seederDll, '--create-new', '--expect-server', $builder.DataSource, '--expect-database', $expectedDatabase,
        '--count', "$Count", '--seed', "$Seed", '--batch-size', "$BatchSize")
    $seedText = (Hide-Secrets ($seedRun.Stdout + "`n" + $seedRun.Stderr) $builder.Password).Trim()
    Write-Host $seedText
    if ($TranscriptPath) { Set-Content -Path $TranscriptPath -Value $seedText -Encoding UTF8 }
    if ($seedRun.ExitCode -ne 0) { Stop-Run 'SEEDER_FAILED' "The Seeder exited with $($seedRun.ExitCode)." }
    if ($seedText -notmatch "database '$expectedDatabase'") { Stop-Run 'SEEDER_TARGET_UNEXPECTED' 'The Seeder output did not name the expected database; inspect it now.' }

    $marker = Invoke-ChildProcess -FileName 'sqlcmd' -ChildEnv @{ 'SQLCMDPASSWORD' = $builder.Password } -Arguments @(
        '-S', $builder.DataSource, '-U', $builder.UserID, '-C', '-b', '-d', $expectedDatabase, '-Q',
        "IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0 AND name = N'T501_PERF_DB') EXEC sp_addextendedproperty @name = N'T501_PERF_DB', @value = N'RequestManagement.T-501'")
    if ($marker.ExitCode -ne 0) { Stop-Run 'MARKER_FAILED' 'The T501_PERF_DB marker could not be written.' }
    $after = Invoke-ChildProcess -FileName 'powershell.exe' `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guardPath, '-CheckServer', '-Container', $Container)
    Write-Host ((Hide-Secrets $after.Stdout $builder.Password).Trim())
    if ($after.ExitCode -ne 0) { Stop-Run 'MARKER_NOT_VERIFIED' 'The guard does not see the marker after seeding.' }
    Write-Host 'EXECUTE OK - database seeded and marked.' -ForegroundColor Green
    exit 0
}
finally {
    if ($isolatedAppData.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $isolatedAppData -Leaf) -like 't501-appdata-*') {
        Remove-Item -LiteralPath $isolatedAppData -Recurse -Force -ErrorAction SilentlyContinue
    }
}
