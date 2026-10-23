<#
.SYNOPSIS
    Offline negative tests for guard-perf-target.ps1. Opens no database connection and runs no sqlcmd:
    every case uses fake credentials and is decided by the static checks alone.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guard = Join-Path $PSScriptRoot 'guard-perf-target.ps1'
$fakePassword = 'unused-test-password'
$envName = 'ConnectionStrings__RequestManagement'
$saved = [Environment]::GetEnvironmentVariable($envName, 'Process')
$results = New-Object System.Collections.Generic.List[object]

function Cs([string]$server, [string]$database, [string]$extra = '') {
    "Server=$server;Database=$database;User Id=sa;Password=$fakePassword;TrustServerCertificate=True$extra"
}

# name, connection string (null = variable not set), expected exit code
$cases = @(
    @('variable not set',                       $null,                                                    1),
    @('variable empty',                         '',                                                       1),
    @('malformed string',                       'this is not;; a connection string=',                      1),
    @('dev database RequestManagement',         (Cs 'localhost,1433' 'RequestManagement'),                1),
    @('SeedCheck database',                     (Cs 'localhost,1433' 'RequestManagement_SeedCheck'),      1),
    @('MigrationCheck database',                (Cs 'localhost,1433' 'RequestManagement_MigrationCheck'), 1),
    @('Perf name, wrong case',                  (Cs 'localhost,1433' 'requestmanagement_perf'),           1),
    @('Perf name with suffix',                  (Cs 'localhost,1433' 'RequestManagement_Perf2'),          1),
    @('master database',                        (Cs 'localhost,1433' 'master'),                           1),
    @('no database named',                      "Server=localhost,1433;User Id=sa;Password=$fakePassword;TrustServerCertificate=True", 1),
    @('remote server',                          (Cs 'sql.example.com,1433' 'RequestManagement_Perf'),     1),
    @('wrong port',                             (Cs 'localhost,1434' 'RequestManagement_Perf'),           1),
    @('no port',                                (Cs 'localhost' 'RequestManagement_Perf'),                1),
    @('named instance',                         (Cs 'localhost\SQLEXPRESS' 'RequestManagement_Perf'),     1),
    @('AttachDbFilename',                       (Cs 'localhost,1433' 'RequestManagement_Perf' ';AttachDbFilename=C:\x.mdf'), 1),
    @('Failover Partner',                       (Cs 'localhost,1433' 'RequestManagement_Perf' ';Failover Partner=other'),    1),
    @('POSITIVE: exact target (static only)',   (Cs 'localhost,1433' 'RequestManagement_Perf'),           0),
    @('POSITIVE: exact target on 127.0.0.1',    (Cs '127.0.0.1,1433' 'RequestManagement_Perf'),           0)
)

try {
    foreach ($case in $cases) {
        $name, $value, $expected = $case
        if ($null -eq $value) { Remove-Item "Env:$envName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($envName, $value, 'Process') }

        # A child process, exactly as the real scripts will call the guard. No -CheckServer: no network access.
        $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard 2>&1 | Out-String)
        $actual = $LASTEXITCODE
        $leaked = $output -match [regex]::Escape($fakePassword)
        $ok = ($actual -eq $expected) -and (-not $leaked)
        $results.Add([pscustomobject]@{ Case = $name; Expected = $expected; Actual = $actual; PasswordLeaked = $leaked; Pass = $ok })
    }
}
finally {
    if ($null -eq $saved) { Remove-Item "Env:$envName" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($envName, $saved, 'Process') }
}

$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("{0} of {1} guard cases behaved as expected." -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
