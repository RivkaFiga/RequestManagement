<#
.SYNOPSIS
    T-501 (work plan section 5.2, step 4): measures the API latency of B1a to B1f and B2 against the dedicated performance
    database and saves api.csv (p50/p95 per scenario), api-calls.csv (every call) and api-run.txt (how the run was made).

.DESCRIPTION
    The caller must define ConnectionStrings__RequestManagement in the process environment. Nothing is read from user-secrets,
    .env or any default, and the connection string is never printed.

    The script starts the API itself, from the Release build, so that the settings that matter are the ones written here and
    not whatever a developer had running: ASPNETCORE_ENVIRONMENT=Production (no user-secrets), Logging__LogLevel__Default=Warning,
    an isolated APPDATA, the explicit connection string and a fixed loopback port. It refuses to start if the port is in use
    (so an API that is already running, possibly against another database, can never be measured by mistake) and stops the
    API again when it is done.

    B1a to B1f and B2 with the cache run on a first API instance (SummaryCache__Enabled=true). B2 without the cache runs on a
    second instance with SummaryCache__Enabled=false (section 5.1: "cache enabled vs. SummaryCache__Enabled=false").

    It never runs the Seeder, never runs dotnet ef, never sends anything but GET requests, and does not write to the database.
    Before it starts anything it runs the guard (with -CheckServer) and checks, read-only through sqlcmd, that the database is in
    the state the phase needs (see run-sql.ps1: PHASE_STATE_MISMATCH).

    Per scenario: 10 warm-up calls (not recorded) and then 100 sequential measured calls. Every call must return HTTP 200 and a
    well-formed body, and every body must carry the same fingerprint (total, number of items, first and last id; for the summary
    the counts); anything else stops the run, because timings of a failing or changing endpoint mean nothing.

    Files written (relative to the results root; T-502 must use the same names for 'after'):
      <Phase>/api.csv        one row per scenario/variant; columns:
                             phase,scenario,variant,cache_enabled,request,warmup_calls,measured_calls,ok_calls,failed_calls,
                             http_status,total_count,items_returned,min_ms,p50_ms,p95_ms,max_ms,mean_ms
                             variant: 'default' (B1a-B1f), 'cache-on' and 'cache-off' (B2). Times are milliseconds with 3 decimals
                             and a dot; p50/p95 are nearest-rank percentiles of the measured calls (the value at position
                             ceil(p * n) of the sorted times).
      <Phase>/api-calls.csv  one row per measured call: phase,scenario,variant,call_index,http_status,elapsed_ms,bytes,total_count,items_returned
      <Phase>/api-run.txt    commit, API build, settings of each instance, counts and API log summary.

    Exit codes: 0 success, 1 stopped (the message names the code; nothing was moved into the results folder).

.PARAMETER Phase
    'before' or 'after'. Required.
.PARAMETER Scenario
    A subset of B1a, B1b, B1c, B1d, B1e, B1f, B2; only together with a -ResultsRoot other than docs/perf/results.
.PARAMETER Port
    Loopback port for the API instances (default 5190). It must be free.
.PARAMETER Overwrite
    Replace the files of this phase if they exist. Without it the run stops with RESULTS_EXIST.
.PARAMETER DryRun
    Print what would happen and stop before any process, database or file is touched.
.PARAMETER KeepWorkOnFailure
    Keep the temporary folder (API logs) after a failure, for diagnosis. By default it is removed, also after an unexpected error.
#>
[CmdletBinding()]
param(
    [ValidateSet('before', 'after')][string]$Phase,
    [ValidateSet('B1a', 'B1b', 'B1c', 'B1d', 'B1e', 'B1f', 'B2')][string[]]$Scenario,
    [string]$ResultsRoot,
    [ValidateRange(1024, 65535)][int]$Port = 5190,
    [int]$ExpectedRowCount = 100000,
    [switch]$DryRun,
    [switch]$Overwrite,
    [switch]$KeepWorkOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PerfTool = 'MEASURE-API'
. (Join-Path $PSScriptRoot 'perf-common.ps1')
$script:PerfKeepOnFailure = [bool]$KeepWorkOnFailure
# An unexpected error (not a Stop-Run) still stops the API and removes the temporary folder.
trap { Invoke-PerfFailureCleanup; break }

$callTimeoutSeconds = 30
$startupTimeoutSeconds = 60
$apiProjectDir = Join-Path $script:PerfRepo 'backend\src\RequestManagement.Api'
$apiDll = Join-Path $apiProjectDir 'bin\Release\net10.0\RequestManagement.Api.dll'
$baseUrl = "http://127.0.0.1:$Port"

# ---- 1. parameters, captured SQL (the request lines), static target check --------------------------------------------
if (-not $Phase) { Stop-Run 'PHASE_MISSING' "-Phase before|after is required." }

$resultsRootFull = Resolve-PerfResultsRoot $ResultsRoot
$isDefaultRoot = Test-PerfDefaultResults $resultsRootFull
if ($Scenario -and $Scenario.Count -gt 0 -and $isDefaultRoot) {
    Stop-Run 'PARTIAL_NEEDS_RESULTSROOT' 'A subset of scenarios would leave an incomplete result set in docs/perf/results. Pass -ResultsRoot with another folder, or run all scenarios.'
}
$selected = @(Get-SelectedScenarios $Scenario)
$sqlFiles = Read-AllPerfSqlFiles $selected
Register-PerfStatements $sqlFiles   # approved hash for every statement and every '-- request:' line, before anything else
if (-not (Test-PerfLoopbackUrl $baseUrl $Port)) { Stop-Run 'URL_NOT_LOOPBACK' "The API address '$baseUrl' is not http://127.0.0.1:<port>." }
$builder = Get-PerfTarget

# The calls: the query string of B1a-B1f is the '-- request:' header of the captured SQL, so the API and the SQL files cannot drift apart.
$calls = New-Object System.Collections.Generic.List[object]
foreach ($scenarioItem in $selected) {
    if ($scenarioItem.Id -eq 'B2') {
        $calls.Add([pscustomobject]@{ Scenario = 'B2'; Variant = 'cache-on'; CacheEnabled = $true; PathAndQuery = '/api/requests/summary' })
        $calls.Add([pscustomobject]@{ Scenario = 'B2'; Variant = 'cache-off'; CacheEnabled = $false; PathAndQuery = '/api/requests/summary' })
        continue
    }
    $request = $sqlFiles[$scenarioItem.Id].Request
    if ($request -notmatch '^[A-Za-z0-9=&:._\-]+$') { Stop-Run 'SQL_FILE_INVALID' "docs/perf/sql/$($scenarioItem.Id).sql has a '-- request:' line that is not a plain query string." }
    $calls.Add([pscustomobject]@{ Scenario = $scenarioItem.Id; Variant = 'default'; CacheEnabled = $true; PathAndQuery = "/api/requests?$request" })
}
$instances = @(@(
    [pscustomobject]@{ CacheEnabled = $true; Calls = @($calls | Where-Object { $_.CacheEnabled }) },
    [pscustomobject]@{ CacheEnabled = $false; Calls = @($calls | Where-Object { -not $_.CacheEnabled }) }
) | Where-Object { @($_.Calls).Count -gt 0 })

# ---- 2. existing results --------------------------------------------------------------------------------------------
$phaseFiles = @(Get-ApiOutputFiles $Phase)
$existing = @(Get-ExistingOutputFiles $resultsRootFull $phaseFiles)
if ($existing.Count -gt 0 -and -not $Overwrite) {
    Stop-Run 'RESULTS_EXIST' "Results already exist and would be replaced: $($existing -join ', '). Nothing was changed. Use -Overwrite only if replacing them is intended."
}

# ---- 3. dry run -----------------------------------------------------------------------------------------------------
if ($DryRun) {
    Write-Host "MEASURE-API DRY RUN - phase '$Phase'. Nothing below is executed: no process is started, no API is run, no database is contacted, no file or folder is written."
    Write-Host "Target (static checks passed): server '$($builder.DataSource)', database '$($builder.InitialCatalog)' (from $($script:PerfEnvName))."
    Write-Host "Results root: $resultsRootFull"
    Write-Host "Request policy (checked now, offline): the requests of $(@($selected).Count) scenario(s) equal their approved hashes; only GET requests to $baseUrl are sent."
    Write-Host 'Would, in this order:'
    Write-Host '  1. verify that the captured SQL is current (git diff), that the Release build of the API exists and is newer than its sources'
    Write-Host '  2. run guard-perf-target.ps1 -CheckServer in a separate process (docker inspect, sqlcmd to master)'
    Write-Host "  3. list the indexes read-only (sqlcmd) and require the '$Phase' state ($(if ($Phase -eq 'before') { 'none of the 5 AddQueryIndexes indexes' } else { 'all 5 AddQueryIndexes indexes' }))"
    Write-Host "  4. require that $baseUrl is free, then start the Release API on it (Production, Logging Warning, isolated APPDATA) once per instance below"
    foreach ($instance in $instances) {
        Write-Host "  API instance: SummaryCache__Enabled=$($instance.CacheEnabled.ToString().ToLowerInvariant())"
        foreach ($call in $instance.Calls) {
            Write-Host "PLAN API: $($call.Scenario) $($call.Variant) cache_enabled=$($call.CacheEnabled.ToString().ToLowerInvariant()) $($script:ApiWarmupCalls) warm-up + $($script:ApiMeasuredCalls) measured GET $($call.PathAndQuery)"
        }
    }
    Write-Host "  5. stop each API instance, write the files below to a temporary folder, and move them into place only if the whole run succeeded$(if ($Overwrite) { ' (-Overwrite: existing files of this phase are replaced)' })"
    foreach ($relative in $phaseFiles) { Write-Host "PLAN FILE: $relative" }
    Write-Host 'DRY RUN OK - nothing was executed.' -ForegroundColor Green
    exit 0
}

# ---- 4. real run: tools, build, source freshness, guard, phase state -------------------------------------------------
foreach ($tool in @('sqlcmd', 'git', 'docker', 'dotnet')) { [void](Resolve-PerfTool $tool) }   # full paths; a tool in the current folder or the repo is refused
if (-not (Test-Path -LiteralPath $apiDll)) {
    Stop-Run 'API_NOT_BUILT' "Build the API first: dotnet build backend\src\RequestManagement.Api -c Release ($apiDll is missing)."
}
$dllTime = (Get-Item -LiteralPath $apiDll).LastWriteTimeUtc
$newerSources = @(
    foreach ($project in @('RequestManagement.Api', 'RequestManagement.Core', 'RequestManagement.Infrastructure')) {
        Get-ChildItem -LiteralPath (Join-Path $script:PerfRepo "backend\src\$project") -Recurse -File -Include *.cs, *.csproj, appsettings*.json |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.LastWriteTimeUtc -gt $dllTime }
    }
)
if ($newerSources.Count -gt 0) {
    Stop-Run 'API_BUILD_STALE' "The Release build is older than $($newerSources.Count) source file(s), for example '$($newerSources[0].Name)'. Rebuild it first."
}
Assert-SqlFilesFresh $sqlFiles
Write-Host 'Source check ok: the query-shaping sources equal the commit the captured SQL was taken from; the Release build is newer than its sources.'
Invoke-ServerGuard $builder
Write-Host 'Guard ok (separate process).'

$work = New-PerfWorkDir
$staging = Join-Path $work 'out'
New-Item -ItemType Directory -Path (Join-Path $staging $Phase) -Force | Out-Null
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$headCommit = (Get-GitText @('rev-parse', 'HEAD')).Text
$dirty = (Get-GitText @('status', '--porcelain', '--', 'backend/src')).Text

$listingRun = Invoke-PerfSqlcmd -Builder $builder -Kind IndexListing -WorkDir $work
$listing = @(ConvertFrom-IndexListing $listingRun.Stdout)
if ($listing.Count -eq 0) { Stop-Run 'INDEX_LISTING_EMPTY' 'The index listing returned no rows; it cannot be checked against the phase.' }
Assert-PhaseIndexState $Phase $listing
Write-Host "Phase state ok: the index listing matches phase '$Phase'."

# Nothing may listen on the port, on any interface: an API that is already running is never measured by mistake.
if (-not (Test-PerfPortFree $Port)) { Stop-Run 'PORT_IN_USE' "Port $Port is already in use (on some interface). Another API may be running; it is not measured. Stop it or pass another -Port." }

# Names of variables that could change how the API behaves; they are removed for its start (names only are ever recorded).
$removedVariableNames = @(Get-PerfApiEnvironmentRemovals ([Environment]::GetEnvironmentVariables('Process')))

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.AllowAutoRedirect = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($callTimeoutSeconds)

# ---- helpers of the real run -----------------------------------------------------------------------------------------
function Set-TemporaryEnvironment([hashtable]$Values) {
    $saved = @{}
    foreach ($key in $Values.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $Values[$key], 'Process')
    }
    $saved
}

function Restore-Environment([hashtable]$Saved) {
    foreach ($key in $Saved.Keys) { [Environment]::SetEnvironmentVariable($key, $Saved[$key], 'Process') }
}

function Invoke-ApiCall([string]$PathAndQuery) {
    $url = $baseUrl + $PathAndQuery
    if (-not (Test-PerfLoopbackUrl $url $Port)) {
        return [pscustomobject]@{ Ok = $false; Status = 0; Body = ''; Ms = 0.0; Error = 'The request address is not http://127.0.0.1:<port>; it was not sent.' }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.GetAsync($url).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $watch.Stop()
        [pscustomobject]@{ Ok = $true; Status = [int]$response.StatusCode; Body = $body; Ms = $watch.Elapsed.TotalMilliseconds; Error = $null }
    }
    catch {
        $watch.Stop()
        [pscustomobject]@{ Ok = $false; Status = 0; Body = ''; Ms = $watch.Elapsed.TotalMilliseconds; Error = $_.Exception.Message }
    }
}

# The body of a successful call as numbers and a fingerprint, or $null when it is not the expected shape.
function ConvertFrom-ApiBody([string]$ScenarioId, [string]$Body) {
    try { $json = $Body | ConvertFrom-Json } catch { return $null }
    if ($null -eq $json) { return $null }
    $names = @($json.PSObject.Properties.Name)
    if ($ScenarioId -eq 'B2') {
        if (@('total', 'byStatus', 'byPriority') | Where-Object { $names -notcontains $_ }) { return $null }
        $byStatus = (@($json.byStatus) | ForEach-Object { "$($_.status):$($_.count)" }) -join ','
        $byPriority = (@($json.byPriority) | ForEach-Object { "$($_.priority):$($_.count)" }) -join ','
        return [pscustomobject]@{ Total = [long]$json.total; Items = 0; Fingerprint = "total=$($json.total);status=$byStatus;priority=$byPriority" }
    }
    if (@('items', 'totalCount', 'page', 'pageSize') | Where-Object { $names -notcontains $_ }) { return $null }
    $items = @($json.items)
    if ($items.Count -gt [int]$json.pageSize) { return $null }
    $first = ''
    $last = ''
    if ($items.Count -gt 0) { $first = [string]$items[0].id; $last = [string]$items[$items.Count - 1].id }
    [pscustomobject]@{ Total = [long]$json.totalCount; Items = $items.Count; Fingerprint = "total=$($json.totalCount);n=$($items.Count);first=$first;last=$last" }
}

function Start-ApiInstance([bool]$CacheEnabled, [string]$LogPrefix) {
    # The API connects to the database, so it needs the guard's approval of exactly this target, checked here and not by call order.
    Assert-GuardApproved $builder
    # The API gets the connection string that was parsed and checked, not the raw text of the environment variable.
    $checkedConnectionString = $builder.ConnectionString
    if (@(Get-PerfTargetFailures -ConnectionString $checkedConnectionString).Count -gt 0) {
        Stop-Run 'TARGET_MISMATCH' 'The normalised connection string no longer names exactly the performance database.'
    }
    $dotnet = Resolve-PerfTool 'dotnet'
    $appData = Join-Path $work ('appdata-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $appData | Out-Null
    $stdout = Join-Path $work "$LogPrefix.out.log"
    $stderr = Join-Path $work "$LogPrefix.err.log"
    $values = @{}
    foreach ($name in $removedVariableNames) { $values[$name] = $null }
    $values['ConnectionStrings__RequestManagement'] = $checkedConnectionString
    $values['ASPNETCORE_URLS'] = $baseUrl
    $values['ASPNETCORE_ENVIRONMENT'] = 'Production'
    $values['DOTNET_ENVIRONMENT'] = 'Production'
    $values['Logging__LogLevel__Default'] = 'Warning'
    $values['SummaryCache__Enabled'] = $CacheEnabled.ToString().ToLowerInvariant()
    $values['APPDATA'] = $appData
    $saved = Set-TemporaryEnvironment $values
    try {
        $process = Start-Process -FilePath $dotnet -ArgumentList @("`"$apiDll`"") -WorkingDirectory (Split-Path $apiDll -Parent) `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    }
    finally { Restore-Environment $saved }
    $script:RunningApi = [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr }

    # Ready = a listener on the port that belongs to the process started here (on 127.0.0.1 only), and it answers. A listener
    # that belongs to anyone else, or an owner that cannot be determined, stops the run before a single request is sent.
    $deadline = (Get-Date).AddSeconds($startupTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            $tail = (Hide-Secrets ((Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)) $builder.Password).Trim()
            Stop-Run 'API_EXITED' "The API exited with $($process.ExitCode) before it was ready. $($tail.Substring(0, [Math]::Min(600, $tail.Length)))"
        }
        $listeners = Get-PerfListeners $Port
        if ($null -eq $listeners) { Stop-Run 'PORT_OWNER_UNVERIFIED' 'Get-NetTCPConnection is not available, so the owner of the port cannot be verified; no request was sent.' }
        if (@($listeners).Count -gt 0) {
            if (-not (Test-ListenerOwnership $listeners $process.Id)) {
                Stop-Run 'PORT_NOT_OURS' "A listener on port $Port does not belong to the API process started by this script (or is not on 127.0.0.1); no request was sent."
            }
            $probe = Invoke-ApiCall '/__t501_ready'
            if ($probe.Ok) { return $script:RunningApi }
        }
        Start-Sleep -Milliseconds 500
    }
    try { Stop-Process -Id $process.Id -Force } catch { }
    Stop-Run 'API_NOT_READY' "The API did not answer on $baseUrl within $startupTimeoutSeconds s."
}

function Stop-ApiInstance($Instance) {
    if (-not $Instance.Process.HasExited) {
        try { Stop-Process -Id $Instance.Process.Id -Force } catch { }
        [void]$Instance.Process.WaitForExit(10000)
    }
    $script:RunningApi = $null
}

# Stop-Run calls this, so that a stop in the middle of a measurement never leaves an API running.
$script:RunningApi = $null
$script:PerfCleanup = { if ($script:RunningApi) { Stop-ApiInstance $script:RunningApi } }

function Measure-ApiCall($Call) {
    $label = "$($Call.Scenario) $($Call.Variant)"
    $fingerprint = $null
    $times = New-Object System.Collections.Generic.List[double]
    $rows = New-Object System.Collections.Generic.List[object]
    $last = $null
    for ($i = 1; $i -le ($script:ApiWarmupCalls + $script:ApiMeasuredCalls); $i++) {
        $measuredCall = $i -gt $script:ApiWarmupCalls
        $result = Invoke-ApiCall $Call.PathAndQuery
        if (-not $result.Ok) { Stop-Run 'API_CALL_FAILED' "$label call ${i}: $($result.Error) (timeout is $callTimeoutSeconds s)." }
        if ($result.Status -ne 200) { Stop-Run 'API_BAD_STATUS' "$label call ${i}: HTTP $($result.Status), expected 200." }
        $parsed = ConvertFrom-ApiBody $Call.Scenario $result.Body
        if ($null -eq $parsed) { Stop-Run 'RESPONSE_INVALID' "$label call ${i}: the body is not the expected JSON shape." }
        if ($null -eq $fingerprint) { $fingerprint = $parsed.Fingerprint }
        elseif ($parsed.Fingerprint -cne $fingerprint) { Stop-Run 'RESPONSE_INCONSISTENT' "$label call ${i}: the response changed during the run ('$($parsed.Fingerprint)' instead of '$fingerprint')." }
        if ($Call.Scenario -eq 'B2' -and $parsed.Total -ne $ExpectedRowCount) {
            Stop-Run 'RESPONSE_UNEXPECTED' "$label : the summary reports $($parsed.Total) requests, expected $ExpectedRowCount. Is the API pointing at the performance database?"
        }
        $last = $parsed
        if ($measuredCall) {
            $times.Add($result.Ms)
            $rows.Add([pscustomobject]@{ Index = $i - $script:ApiWarmupCalls; Status = $result.Status; Ms = $result.Ms; Bytes = $result.Body.Length; Total = $parsed.Total; Items = $parsed.Items })
        }
    }
    [pscustomobject]@{ Call = $Call; Times = @($times.ToArray()); Rows = @($rows.ToArray()); Last = $last }
}

# ---- 5. measurements -------------------------------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$runLines = New-Object System.Collections.Generic.List[string]
$runLines.Add("T-501 - API measurement run, phase '$Phase'")
$runLines.Add("Captured: $stamp local time by measure-api.ps1. HEAD $headCommit. backend/src has uncommitted changes: $(if ($dirty) { 'YES' } else { 'no' }).")
$runLines.Add("Database: $($script:PerfDatabase) on $($builder.DataSource); the index listing matched phase '$Phase'.")
$runLines.Add("API build: $apiDll  sha256 $((Get-FileHash -Algorithm SHA256 -LiteralPath $apiDll).Hash)  built $($dllTime.ToString('o'))")
$runLines.Add("Settings of every instance: ASPNETCORE_ENVIRONMENT=Production, Logging__LogLevel__Default=Warning, ASPNETCORE_URLS=$baseUrl, isolated APPDATA, the checked connection string.")
$runLines.Add("Variables removed from the API's environment before its start (names only): $(if ($removedVariableNames.Count -gt 0) { $removedVariableNames -join ', ' } else { '(none)' })")
$runLines.Add("Calls: $($script:ApiWarmupCalls) warm-up (not recorded) and $($script:ApiMeasuredCalls) sequential measured calls per scenario/variant; per-call timeout $callTimeoutSeconds s; every call must be HTTP 200 with the same fingerprint.")
$runLines.Add("Percentiles: nearest-rank on the measured calls (the value at position ceil(p * n) of the sorted times). Times are wall-clock milliseconds from sending the request to reading the whole body, on this machine, over loopback.")
$apiProblems = New-Object System.Collections.Generic.List[string]

$instanceNumber = 0
foreach ($instance in $instances) {
    $instanceNumber++
    $enabledText = $instance.CacheEnabled.ToString().ToLowerInvariant()
    Write-Host "Starting API instance $instanceNumber (SummaryCache__Enabled=$enabledText) on $baseUrl ..."
    $api = Start-ApiInstance $instance.CacheEnabled "api$instanceNumber"
    try {
        $runLines.Add('')
        $runLines.Add("instance ${instanceNumber}: SummaryCache__Enabled=$enabledText (pid $($api.Process.Id))")
        foreach ($call in $instance.Calls) {
            Write-Host "[$($call.Scenario) $($call.Variant)] $($script:ApiWarmupCalls) warm-up + $($script:ApiMeasuredCalls) measured calls..."
            $measurement = Measure-ApiCall $call
            if ($api.Process.HasExited) { Stop-Run 'API_EXITED' "The API exited during $($call.Scenario) $($call.Variant)." }
            $results.Add($measurement)
            $p50 = Get-NearestRank $measurement.Times 0.50
            $p95 = Get-NearestRank $measurement.Times 0.95
            Write-Host "[$($call.Scenario) $($call.Variant)] p50 $(Format-Number $p50) ms, p95 $(Format-Number $p95) ms."
            $runLines.Add("  $($call.Scenario) $($call.Variant): GET $($call.PathAndQuery)  total=$($measurement.Last.Total) items=$($measurement.Last.Items)  p50 $(Format-Number $p50) ms  p95 $(Format-Number $p95) ms")
        }
    }
    finally {
        Stop-ApiInstance $api
    }
    $logText = ((Get-Content -LiteralPath $api.Stdout -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content -LiteralPath $api.Stderr -Raw -ErrorAction SilentlyContinue))
    $problemLines = @(($logText -split "`r?`n") | Where-Object { $_ -match '^(warn|fail|crit):' })
    foreach ($line in $problemLines) { $apiProblems.Add("instance ${instanceNumber}: $line") }
}
$client.Dispose()
$runLines.Add('')
$runLines.Add("API log lines at warn/fail/crit level (the log level was Warning): $($apiProblems.Count)")
foreach ($line in ($apiProblems | Select-Object -First 20)) { $runLines.Add("  $(Hide-Secrets $line $builder.Password)") }

# ---- 6. the files ---------------------------------------------------------------------------------------------------------
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('phase,scenario,variant,cache_enabled,request,warmup_calls,measured_calls,ok_calls,failed_calls,http_status,total_count,items_returned,min_ms,p50_ms,p95_ms,max_ms,mean_ms')
$perCall = New-Object System.Collections.Generic.List[string]
$perCall.Add('phase,scenario,variant,call_index,http_status,elapsed_ms,bytes,total_count,items_returned')
foreach ($measurement in $results) {
    $call = $measurement.Call
    $times = $measurement.Times
    $stats = $times | Measure-Object -Minimum -Maximum -Average
    $summary.Add(('{0},{1},{2},{3},"{4}",{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16}' -f
        $Phase, $call.Scenario, $call.Variant, $call.CacheEnabled.ToString().ToLowerInvariant(), $call.PathAndQuery,
        $script:ApiWarmupCalls, $script:ApiMeasuredCalls, $times.Count, 0, 200, $measurement.Last.Total, $measurement.Last.Items,
        (Format-Number $stats.Minimum), (Format-Number (Get-NearestRank $times 0.50)), (Format-Number (Get-NearestRank $times 0.95)),
        (Format-Number $stats.Maximum), (Format-Number $stats.Average)))
    foreach ($row in $measurement.Rows) {
        $perCall.Add(('{0},{1},{2},{3},{4},{5},{6},{7},{8}' -f $Phase, $call.Scenario, $call.Variant, $row.Index, $row.Status, (Format-Number $row.Ms), $row.Bytes, $row.Total, $row.Items))
    }
}
Write-Utf8NoBom (Join-Path $staging "$Phase/api.csv") (($summary -join "`n") + "`n")
Write-Utf8NoBom (Join-Path $staging "$Phase/api-calls.csv") (($perCall -join "`n") + "`n")
Write-Utf8NoBom (Join-Path $staging "$Phase/api-run.txt") (($runLines -join "`n") + "`n")

# One transaction: all three files are in place, or none is changed.
Publish-PerfOutput $staging $resultsRootFull $phaseFiles ([bool]$Overwrite)
[void](Remove-PerfWorkDir $work)
Write-Host "MEASURE-API OK - phase '$Phase': $($phaseFiles.Count) files written under $(Join-Path $resultsRootFull $Phase). Only GET requests were sent." -ForegroundColor Green
exit 0
