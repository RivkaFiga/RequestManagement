<#
.SYNOPSIS
    Offline negative tests for run-seeder.ps1. Every case uses a fake password, so even a bug could not log in; the
    expected stop must come from the first checks, before any child process or database is involved.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'run-seeder.ps1'
$fake = 'unused-test-password'
$envName = 'ConnectionStrings__RequestManagement'
$saved = [Environment]::GetEnvironmentVariable($envName, 'Process')
$results = New-Object System.Collections.Generic.List[object]

function Cs([string]$server, [string]$database) { "Server=$server;Database=$database;User Id=sa;Password=$fake;TrustServerCertificate=True" }

# name, connection string (null = unset), extra arguments, expected stop code
$cases = @(
    @('variable not set (Preflight)',            $null,                                                @(),                                      'ENV_MISSING'),
    @('variable not set (Execute)',              $null,                                                @('-Mode', 'Execute', '-ConfirmDatabase', 'RequestManagement_Perf'), 'ENV_MISSING'),
    @('dev database',                            (Cs 'localhost,1433' 'RequestManagement'),            @(),                                      'TARGET_MISMATCH'),
    @('dev database (Execute, confirmed)',       (Cs 'localhost,1433' 'RequestManagement'),            @('-Mode', 'Execute', '-ConfirmDatabase', 'RequestManagement_Perf'), 'TARGET_MISMATCH'),
    @('SeedCheck database',                      (Cs 'localhost,1433' 'RequestManagement_SeedCheck'),  @(),                                      'TARGET_MISMATCH'),
    @('remote server',                           (Cs 'sql.example.com,1433' 'RequestManagement_Perf'), @(),                                      'TARGET_MISMATCH'),
    @('wrong port',                              (Cs 'localhost,1434' 'RequestManagement_Perf'),       @(),                                      'TARGET_MISMATCH'),
    @('Perf name in wrong case',                 (Cs 'localhost,1433' 'requestmanagement_perf'),       @(),                                      'TARGET_MISMATCH'),
    @('Execute without -ConfirmDatabase',        (Cs 'localhost,1433' 'RequestManagement_Perf'),       @('-Mode', 'Execute'),                    'CONFIRM_MISSING'),
    @('Execute with the wrong confirmation',     (Cs 'localhost,1433' 'RequestManagement_Perf'),       @('-Mode', 'Execute', '-ConfirmDatabase', 'RequestManagement'), 'CONFIRM_MISSING'),
    @('exact target, fake password (guard must stop it)', (Cs 'localhost,1433' 'RequestManagement_Perf'), @(),                                   'GUARD_FAILED')
)

try {
    foreach ($case in $cases) {
        $name, $value, $extra, $code = $case
        if ($null -eq $value) { Remove-Item "Env:$envName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($envName, $value, 'Process') }

        $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @extra 2>&1 | Out-String)
        $exit = $LASTEXITCODE
        $stoppedWithCode = $output -match [regex]::Escape("[$code]")
        $leaked = $output -match [regex]::Escape($fake)
        $startedSeeder = $output -match 'Starting the Seeder|P4 ok|P5 ok|P6 ok'
        $ok = ($exit -eq 1) -and $stoppedWithCode -and (-not $leaked) -and (-not $startedSeeder)
        $results.Add([pscustomobject]@{ Case = $name; ExpectedCode = $code; Exit = $exit; CodeSeen = $stoppedWithCode; PasswordLeaked = $leaked; ReachedChildChecks = $startedSeeder; Pass = $ok })
    }
}
finally {
    if ($null -eq $saved) { Remove-Item "Env:$envName" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($envName, $saved, 'Process') }
}

$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ("{0} of {1} run-seeder cases stopped as expected." -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
