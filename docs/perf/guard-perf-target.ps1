<#
.SYNOPSIS
    T-501 safety guard: continue only if the connection string in the PROCESS ENVIRONMENT targets exactly
    the dedicated performance database. Run it before the Seeder (--reset drops the database), before
    `dotnet ef database update`, and at the start of run-sql.ps1 / measure-api.ps1.

.DESCRIPTION
    Why the guard exists: the Seeder falls back to user-secrets when ConnectionStrings__RequestManagement is not
    set, and its own safety check only requires DOTNET_ENVIRONMENT=Development and a non-system database name.
    Without this guard a forgotten variable could make `--reset` drop the development database.

    Static checks (no network, no database access):
      1. ConnectionStrings__RequestManagement is defined in the process environment and not empty.
      2. It parses as a SQL Server connection string.
      3. Database is exactly 'RequestManagement_Perf' (case-sensitive).
      4. Server is exactly 'localhost,1433' or '127.0.0.1,1433'.
      5. No AttachDbFilename / Failover Partner redirection.

    With -CheckServer (only after the static checks pass; connects to master, and to the Perf database only if it exists):
      6. The SQL Server container is running and healthy, and publishes the expected port.
      7. The Perf database is either absent (it may be created) or carries the extended property
         T501_PERF_DB = 'RequestManagement.T-501' (it is recognised as the Perf database; the guard passes, but
         run-seeder.ps1 -Mode Execute only creates and stops on an existing database). Any other existing database
         with that name stops the run.

    Exit code 0 = safe to continue. Any other exit code = stop; nothing was written to any database.
    The connection string and the password are never printed.
#>
[CmdletBinding()]
param(
    [switch]$CheckServer,
    [string]$Container = 'request-management-sql'
)

Set-StrictMode -Version Latest

$script:EnvName = 'ConnectionStrings__RequestManagement'
$script:ExpectedDatabase = 'RequestManagement_Perf'
$script:AllowedServers = @('localhost,1433', '127.0.0.1,1433')
$script:MarkerName = 'T501_PERF_DB'
$script:MarkerValue = 'RequestManagement.T-501'

function Get-PerfTargetFailures {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$ConnectionString)

    $failures = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        $failures.Add("$script:EnvName is not set in the process environment (the Seeder would fall back to user-secrets).")
        return $failures.ToArray()
    }

    $builder = $null
    try {
        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($ConnectionString)
    }
    catch {
        $failures.Add('The connection string is malformed.')
        return $failures.ToArray()
    }

    if ($builder.InitialCatalog -cne $script:ExpectedDatabase) {
        $failures.Add("Database is '$($builder.InitialCatalog)', expected exactly '$script:ExpectedDatabase'.")
    }
    if ($script:AllowedServers -cnotcontains $builder.DataSource) {
        $failures.Add("Server is '$($builder.DataSource)', expected one of: $($script:AllowedServers -join ', ').")
    }
    if (-not [string]::IsNullOrEmpty($builder.AttachDBFilename)) {
        $failures.Add('AttachDbFilename is not allowed.')
    }
    if (-not [string]::IsNullOrEmpty($builder.FailoverPartner)) {
        $failures.Add('Failover Partner is not allowed.')
    }

    return $failures.ToArray()
}

function Invoke-GuardSqlcmd {
    param([System.Data.SqlClient.SqlConnectionStringBuilder]$Builder, [string]$Database, [string]$Query)

    $previous = $env:SQLCMDPASSWORD
    try {
        $env:SQLCMDPASSWORD = $Builder.Password
        $output = & sqlcmd -S $Builder.DataSource -U $Builder.UserID -C -b -h -1 -W -d $Database -Q "SET NOCOUNT ON; $Query"
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed with exit code $LASTEXITCODE." }
        return ($output | Out-String).Trim()
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue } else { $env:SQLCMDPASSWORD = $previous }
    }
}

function Get-PerfServerFailures {
    [CmdletBinding()]
    param([string]$ConnectionString, [string]$Container)

    $failures = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($ConnectionString)

    $state = (& docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' $Container 2>$null)
    if ($LASTEXITCODE -ne 0 -or $state -ne 'running/healthy') {
        $failures.Add("Container '$Container' is not running and healthy (state: '$state').")
        return $failures.ToArray()
    }
    $port = ($builder.DataSource -split ',')[1]
    $published = (& docker port $Container 1433/tcp 2>$null | Out-String)
    if ($published -notmatch (":$port\s*$")) {
        $failures.Add("Container '$Container' does not publish 1433/tcp on host port $port.")
        return $failures.ToArray()
    }

    try {
        $exists = Invoke-GuardSqlcmd -Builder $builder -Database 'master' `
            -Query "SELECT COUNT(*) FROM sys.databases WHERE name = N'$script:ExpectedDatabase'"
        if ($exists -eq '0') {
            Write-Host "Server check: '$script:ExpectedDatabase' does not exist; it may be created."
        }
        elseif ($exists -eq '1') {
            $marked = Invoke-GuardSqlcmd -Builder $builder -Database 'master' -Query (
                "SELECT COUNT(*) FROM [$script:ExpectedDatabase].sys.extended_properties " +
                "WHERE class = 0 AND name = N'$script:MarkerName' AND CAST(value AS nvarchar(100)) = N'$script:MarkerValue'")
            if ($marked -eq '1') {
                Write-Host "Server check: '$script:ExpectedDatabase' exists and carries the $script:MarkerName marker; run-seeder.ps1 -Mode Execute still refuses it (create-only). Resetting needs separate explicit approval."
            }
            else {
                $failures.Add("'$script:ExpectedDatabase' exists WITHOUT the $script:MarkerName marker; it is not known to be dedicated to T-501.")
            }
        }
        else {
            $failures.Add("Unexpected result from sys.databases: '$exists'.")
        }
    }
    catch {
        $failures.Add('Server check failed: ' + $_.Exception.Message)
    }

    return $failures.ToArray()
}

# Dot-sourcing (the self-test does this) only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $connectionString = [Environment]::GetEnvironmentVariable($script:EnvName, 'Process')
    $failures = @(Get-PerfTargetFailures -ConnectionString $connectionString)

    if ($failures.Count -eq 0 -and $CheckServer) {
        $failures = @(Get-PerfServerFailures -ConnectionString $connectionString -Container $Container)
    }

    if ($failures.Count -gt 0) {
        Write-Host 'GUARD: STOP - the target is not the dedicated T-501 database. Nothing was written to any database.' -ForegroundColor Red
        $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }

    $target = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connectionString)
    Write-Host "GUARD: OK - server '$($target.DataSource)', database '$($target.InitialCatalog)' (from $script:EnvName)."
    exit 0
}
