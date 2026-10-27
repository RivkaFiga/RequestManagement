<#
.SYNOPSIS
    T-501 (work plan section 5.2, step 3): measures the captured SQL of B1a to B1d and B2 against the dedicated performance
    database and saves the statistics, the actual plans and the checks that tie them together.

.DESCRIPTION
    The caller must define ConnectionStrings__RequestManagement in the process environment. Nothing is read from user-secrets,
    .env or any default, and the connection string is never printed.

    The script only reads. Every SQL text goes through Assert-ReadOnlySql (SET, SELECT, EXEC sp_executesql; no DDL, DML, DBCC
    or other procedures). It never starts the Seeder, never runs dotnet ef and never changes the schema: putting the database
    in the 'before' state (step 2) or the 'after' state (step 5) is a separate, explicitly approved action, and this script
    stops with PHASE_STATE_MISMATCH if the database is in the wrong state for the phase it was asked to measure.

    Order of a run:
      1. parameters, then the captured SQL files (docs/perf/sql), then the static target check (the guard's offline checks);
      2. the existing results are looked up (RESULTS_EXIST unless -Overwrite);
      3. -DryRun prints the plan and stops here: no process is started, no file or folder is written;
      4. the guard with -CheckServer (separate process), sqlcmd, git (source freshness);
      5. the index listing must match the phase; the dataset must equal the expected row count and checksum;
      6. per statement: 1 warm-up and 5 measured executions with STATISTICS IO, TIME and XML OFF, then one execution with XML ON
         that is used only for the .sqlplan (docs/perf/DEVIATIONS.md, deviation B);
      7. plan fidelity (query_plan_hash of every execution of the statement, from the plan cache);
      8. everything is written to a temporary folder and moved into <ResultsRoot>/<Phase>/ only when the whole run succeeded.

    Files written (relative to the results root; T-502 must use the same names for 'after'):
      <Phase>/indexes.txt, <Phase>/dataset-check.txt, <Phase>/fidelity.txt,
      <Phase>/<scenario>.stats.txt                one per scenario (IO and TIME of all its statements; deviation A),
      <Phase>/<scenario>.<part>.sqlplan           one per statement (count|data for B1a-B1d, status|priority for B2),
      environment.txt                             only in phase 'before', only when it does not exist yet.

    Exit codes: 0 success, 1 stopped (the message names the code; nothing was moved into the results folder).

.PARAMETER Phase
    'before' or 'after'. Required.
.PARAMETER Scenario
    A subset of B1a, B1b, B1c, B1d, B2. A subset is only accepted together with a -ResultsRoot other than docs/perf/results,
    so that a partial set can never be mistaken for the official results.
.PARAMETER ResultsRoot
    Defaults to docs/perf/results.
.PARAMETER Overwrite
    Replace the files of this phase if they exist. Without it the run stops with RESULTS_EXIST. environment.txt is never replaced.
.PARAMETER DryRun
    Print what would happen and stop before any process, database or file is touched.
.PARAMETER KeepWorkOnFailure
    Keep the temporary folder (SQL batches) after a failure, for diagnosis. By default it is removed, also after an unexpected error.
#>
[CmdletBinding()]
param(
    [ValidateSet('before', 'after')][string]$Phase,
    [ValidateSet('B1a', 'B1b', 'B1c', 'B1d', 'B2')][string[]]$Scenario,
    [string]$ResultsRoot,
    [int]$ExpectedRowCount = 100000,
    [long]$ExpectedChecksum = -1953119262,
    [switch]$DryRun,
    [switch]$Overwrite,
    [switch]$KeepWorkOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PerfTool = 'RUN-SQL'
. (Join-Path $PSScriptRoot 'perf-common.ps1')
$script:PerfKeepOnFailure = [bool]$KeepWorkOnFailure
# An unexpected error (not a Stop-Run) still removes the temporary folder.
trap { Invoke-PerfFailureCleanup; break }

# ---- 1. parameters, captured SQL, static target check ----------------------------------------------------------------
if (-not $Phase) { Stop-Run 'PHASE_MISSING' "-Phase before|after is required." }

$resultsRootFull = Resolve-PerfResultsRoot $ResultsRoot
$isDefaultRoot = Test-PerfDefaultResults $resultsRootFull
if ($Scenario -and $Scenario.Count -gt 0 -and $isDefaultRoot) {
    Stop-Run 'PARTIAL_NEEDS_RESULTSROOT' 'A subset of scenarios would leave an incomplete result set in docs/perf/results. Pass -ResultsRoot with another folder, or run all scenarios.'
}
$selected = @(Get-SelectedScenarios $Scenario)
$sqlFiles = Read-AllPerfSqlFiles $selected
Register-PerfStatements $sqlFiles   # approved hash AND read-only grammar for every statement, before anything else
$builder = Get-PerfTarget

# ---- 2. existing results --------------------------------------------------------------------------------------------
$phaseFiles = @(Get-SqlOutputFiles $Phase $selected)
$environmentPath = Join-Path $resultsRootFull $script:PerfEnvironmentFile
$writeEnvironment = ($Phase -eq 'before') -and (-not (Test-Path -LiteralPath $environmentPath))
$existing = @(Get-ExistingOutputFiles $resultsRootFull $phaseFiles)
if ($existing.Count -gt 0 -and -not $Overwrite) {
    Stop-Run 'RESULTS_EXIST' "Results already exist and would be replaced: $($existing -join ', '). Nothing was changed. Use -Overwrite only if replacing them is intended."
}

# ---- 3. dry run -----------------------------------------------------------------------------------------------------
$executionsPerPart = $script:SqlWarmupRuns + $script:SqlMeasuredRuns + 1
$partCount = @($selected | ForEach-Object { $_.Parts }).Count
if ($DryRun) {
    Write-Host "RUN-SQL DRY RUN - phase '$Phase'. Nothing below is executed: no process is started, no database is contacted, no file or folder is written."
    Write-Host "Target (static checks passed): server '$($builder.DataSource)', database '$($builder.InitialCatalog)' (from $($script:PerfEnvName))."
    Write-Host "Results root: $resultsRootFull"
    Write-Host "SQL policy (checked now, offline): $partCount statements equal their approved hashes and pass the read-only grammar."
    Write-Host 'Would, in this order:'
    Write-Host "  1. verify that the captured SQL is current (git diff against the commit in each docs/perf/sql header)"
    Write-Host "  2. run guard-perf-target.ps1 -CheckServer in a separate process (docker inspect, sqlcmd to master)"
    Write-Host "  3. list the indexes of '$($builder.InitialCatalog)' and require the '$Phase' state ($(if ($Phase -eq 'before') { 'none of the 5 AddQueryIndexes indexes' } else { 'all 5 AddQueryIndexes indexes' }))"
    Write-Host "  4. check the dataset: $ExpectedRowCount rows and checksum $ExpectedChecksum"
    Write-Host "  5. for each of the $partCount statements: $($script:SqlWarmupRuns) warm-up and $($script:SqlMeasuredRuns) measured executions (STATISTICS IO, TIME; XML off), then 1 execution with XML on for the plan ($executionsPerPart sqlcmd calls per statement)"
    Write-Host "  6. read the plan cache for the query_plan_hash of every statement (fidelity)"
    Write-Host "  7. write the files below to a temporary folder and move them into place only if the whole run succeeded$(if ($Overwrite) { ' (-Overwrite: existing files of this phase are replaced)' })"
    foreach ($relative in $phaseFiles) { Write-Host "PLAN FILE: $relative" }
    if ($writeEnvironment) { Write-Host "PLAN FILE: $($script:PerfEnvironmentFile) (written only because it does not exist yet; never overwritten)" }
    Write-Host 'DRY RUN OK - nothing was executed.' -ForegroundColor Green
    exit 0
}

# ---- 4. real run: tools, source freshness, guard ---------------------------------------------------------------------
foreach ($tool in @('sqlcmd', 'git', 'docker')) { [void](Resolve-PerfTool $tool) }   # full paths; a tool in the current folder or the repo is refused
Assert-SqlFilesFresh $sqlFiles
Write-Host 'Source check ok: the query-shaping sources equal the commit the captured SQL was taken from.'
Invoke-ServerGuard $builder
Write-Host 'Guard ok (separate process).'

$work = New-PerfWorkDir
$staging = Join-Path $work 'out'
New-Item -ItemType Directory -Path (Join-Path $staging $Phase) -Force | Out-Null
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$headCommit = (Get-GitText @('rev-parse', 'HEAD')).Text

# ---- 5. phase state and dataset ---------------------------------------------------------------------------------------
$listingRun = Invoke-PerfSqlcmd -Builder $builder -Kind IndexListing -WorkDir $work
$listing = @(ConvertFrom-IndexListing $listingRun.Stdout)
if ($listing.Count -eq 0) { Stop-Run 'INDEX_LISTING_EMPTY' 'The index listing returned no rows; it cannot be checked against the phase.' }
Assert-PhaseIndexState $Phase $listing
Write-Host "Phase state ok: the index listing matches phase '$Phase'."

$indexLines = New-Object System.Collections.Generic.List[string]
$indexLines.Add("T-501 - indexes present in $($script:PerfDatabase), phase '$Phase'")
$indexLines.Add("Captured: $stamp local time by run-sql.ps1 (read-only sys.indexes / sys.index_columns / sys.dm_db_partition_stats). HEAD $headCommit.")
$indexLines.Add("Phase check: " + $(if ($Phase -eq 'before') { 'none of the 5 AddQueryIndexes indexes is present (required for phase before).' } else { 'all 5 AddQueryIndexes indexes are present (required for phase after).' }))
$indexLines.Add('Fields: Table | Index | Type | Keys | Included | Rows | Pages')
foreach ($row in $listing) { $indexLines.Add("$($row.Table) | $($row.Index) | $($row.Type) | $($row.Keys) | $($row.Included) | $($row.Rows) | $($row.Pages)") }
Write-Utf8NoBom (Join-Path $staging "$Phase/indexes.txt") (($indexLines -join "`n") + "`n")

$datasetRun = Invoke-PerfSqlcmd -Builder $builder -Kind DatasetCheck -WorkDir $work
$datasetLine = @(($datasetRun.Stdout -split "`r?`n") | Where-Object { $_ -match '^\d+\|-?\d+$' })
if ($datasetLine.Count -ne 1) { Stop-Run 'DATASET_CHECK_FAILED' 'The dataset query did not return one row|checksum line.' }
$actualRows, $actualChecksum = $datasetLine[0] -split '\|'
if ([long]$actualRows -ne $ExpectedRowCount -or [long]$actualChecksum -ne $ExpectedChecksum) {
    Stop-Run 'DATASET_MISMATCH' "The database holds $actualRows rows with checksum $actualChecksum; expected $ExpectedRowCount rows with checksum $ExpectedChecksum. Results from a different dataset cannot be compared (section 5.4)."
}
Write-Utf8NoBom (Join-Path $staging "$Phase/dataset-check.txt") (@(
    "T-501 - dataset check, phase '$Phase'",
    "Captured: $stamp local time by run-sql.ps1 (read-only). HEAD $headCommit.",
    "Database: $($script:PerfDatabase) on $($builder.DataSource)",
    "rows: $actualRows (expected $ExpectedRowCount): match",
    "checksum: $actualChecksum (expected $ExpectedChecksum): match",
    "checksum_query: SELECT CHECKSUM_AGG(CHECKSUM([Id],[Title],[OrganizationName],[Status],[Priority],[AssignedTo],[CreatedAt],[UpdatedAt])) FROM dbo.Requests   (same formula as results/dataset.txt)"
) -join "`n")
Write-Host "Dataset ok: $actualRows rows, checksum $actualChecksum."

# ---- 6. and 7. measurements and fidelity -----------------------------------------------------------------------------
function Invoke-StatsRun([string]$Label, [string]$StatementId, [bool]$Xml) {
    $run = Invoke-PerfSqlcmd -Builder $builder -Kind StatsRun -StatementId $StatementId -WorkDir $work -Xml:$Xml
    $parsed = ConvertFrom-StatsOutput $run.Stdout
    if ($null -eq $parsed.CpuMs -or $null -eq $parsed.Rows -or $parsed.LogicalReads.Count -eq 0) {
        $head = $run.Stdout.Substring(0, [Math]::Min(400, $run.Stdout.Length))
        Stop-Run 'STATS_PARSE_FAILED' "$Label : the STATISTICS output has an unexpected shape (tables $($parsed.LogicalReads.Count), cpu '$($parsed.CpuMs)', rows '$($parsed.Rows)'). Start: $head"
    }
    [pscustomobject]@{ Parsed = $parsed; Raw = $run.Stdout }
}

$fidelityLines = New-Object System.Collections.Generic.List[string]
$fidelityLines.Add("T-501 - plan fidelity, phase '$Phase' (docs/perf/DEVIATIONS.md, deviation B)")
$fidelityLines.Add("Captured: $stamp local time by run-sql.ps1. HEAD $headCommit.")
$fidelityLines.Add("Timings come from executions with STATISTICS XML off; the .sqlplan comes from one more execution with XML on. The plan is accepted as the plan of the timed runs only if the plan cache holds exactly one query_plan_hash for the statement and it equals the QueryPlanHash of the saved plan.")
$fidelityLines.Add("Fields per statement: verdict, xml_plan_hash, then one line per hash in the plan cache: hash | executions | first compiled | last executed.")
$minimumExecutions = $script:SqlWarmupRuns + $script:SqlMeasuredRuns + 1

foreach ($scenarioItem in $selected) {
    $file = $sqlFiles[$scenarioItem.Id]
    $stats = New-Object System.Collections.Generic.List[string]
    $stats.Add("T-501 - STATISTICS IO / TIME, scenario $($scenarioItem.Id), phase '$Phase'")
    $stats.Add("Captured: $stamp local time by run-sql.ps1. HEAD $headCommit. Database $($script:PerfDatabase) on $($builder.DataSource).")
    $stats.Add("sql_file: docs/perf/sql/$($scenarioItem.Id).sql  sha256: $($file.Sha256)  captured_from_commit: $($file.Commit)")
    $stats.Add("request: $($file.Request)")
    $stats.Add("Method: per statement $($script:SqlWarmupRuns) warm-up (discarded) and $($script:SqlMeasuredRuns) measured executions with STATISTICS IO and TIME on and XML off; medians come from those only. One further execution with XML on is kept under its own heading and is NOT used for any median (deviation B).")
    $stats.Add("Rule: cpu_ms and elapsed_ms of an execution are the values of the last 'SQL Server Execution Times' block of its output.")

    foreach ($part in $file.Parts) {
        $label = "$($scenarioItem.Id).$($part.Name)"
        Write-Host "[$label] $($script:SqlWarmupRuns) warm-up, $($script:SqlMeasuredRuns) measured, 1 plan execution..."
        $warm = @(1..$script:SqlWarmupRuns | ForEach-Object { Invoke-StatsRun "$label warm-up" $label $false })
        $measured = @(1..$script:SqlMeasuredRuns | ForEach-Object { Invoke-StatsRun "$label measured" $label $false })
        $xmlRun = Invoke-StatsRun "$label plan" $label $true

        # The data must be the same in every execution, or the timings are not comparable.
        $all = @($warm) + @($measured)
        if (@($all | ForEach-Object { $_.Parsed.Rows } | Sort-Object -Unique).Count -ne 1 -or
            @($all | ForEach-Object { $_.Parsed.ResultSha256 } | Sort-Object -Unique).Count -ne 1 -or
            $xmlRun.Parsed.Rows -ne $measured[0].Parsed.Rows) {
            Stop-Run 'RESULT_UNSTABLE' "$label : the executions did not return the same rows. The data changed during the run or the query is not deterministic."
        }

        $plans = @(Get-ShowPlans $xmlRun.Raw)
        if ($plans.Count -ne 1) { Stop-Run 'PLAN_COUNT' "$label : expected exactly one ShowPlanXML document, found $($plans.Count)." }
        try { [void]([xml]$plans[0]) } catch { Stop-Run 'PLAN_INVALID' "$label : the plan is not well-formed XML (it may have been truncated or wrapped by sqlcmd)." }
        $planHashes = @(Get-PlanHashes $plans[0])
        if ($planHashes.Count -ne 1) { Stop-Run 'PLAN_INVALID' "$label : expected one QueryPlanHash in the plan, found $($planHashes.Count)." }
        $hasRuntimeInfo = $plans[0].Contains('RunTimeInformation')
        Write-Utf8NoBom (Join-Path $staging "$Phase/$label.sqlplan") $plans[0]

        $first = $measured[0].Parsed
        $stats.Add('')
        $stats.Add("== part: $($part.Name)")
        $stats.Add("rows_returned: $($first.Rows)")
        if ($null -ne $first.CountValue -and $part.Name -eq 'count') { $stats.Add("count_value: $($first.CountValue)") }
        $stats.Add("result_sha256: $($first.ResultSha256)   (hash of the result lines; equal before and after means equal data and order)")
        foreach ($table in $first.LogicalReads.Keys) {
            $reads = @($measured | ForEach-Object { [long]$_.Parsed.LogicalReads[$table] })
            $identical = (@($reads | Sort-Object -Unique).Count -eq 1)
            $stats.Add("logical_reads.${table}: $(Format-Number (Get-Median $reads) 0)   runs: $($reads -join ',')   identical_in_all_runs: $(if ($identical) { 'yes' } else { 'NO (recorded, not hidden)' })")
        }
        $cpuRuns = @($measured | ForEach-Object { [long]$_.Parsed.CpuMs })
        $elapsedRuns = @($measured | ForEach-Object { [long]$_.Parsed.ElapsedMs })
        $stats.Add("cpu_ms.median: $(Format-Number (Get-Median $cpuRuns) 1)   runs: $($cpuRuns -join ',')")
        $stats.Add("elapsed_ms.median: $(Format-Number (Get-Median $elapsedRuns) 1)   runs: $($elapsedRuns -join ',')")
        $stats.Add("plan_file: $Phase/$label.sqlplan   xml_plan_hash: $($planHashes[0])   actual_plan_run_time_information: $(if ($hasRuntimeInfo) { 'present' } else { 'ABSENT (check that this is an actual plan)' })")
        $stats.Add("-- verbatim STATISTICS output of the $($script:SqlWarmupRuns) warm-up execution(s), not used for medians")
        foreach ($w in $warm) { foreach ($line in $w.Parsed.MessageLines) { $stats.Add("   warm-up | $line") } }
        $runNumber = 0
        foreach ($m in $measured) {
            $runNumber++
            $stats.Add("-- verbatim STATISTICS output, measured run $runNumber (XML off)")
            foreach ($line in $m.Parsed.MessageLines) { $stats.Add("   $line") }
        }
        $stats.Add("-- execution with STATISTICS XML on (plan only; its IO and TIME are NOT used for the medians)")
        foreach ($line in $xmlRun.Parsed.MessageLines) { $stats.Add("   xml-on | $line") }

        # Plan fidelity: every execution of this statement in the plan cache must have used the saved plan.
        # Only plans compiled in the performance database count (the query filters on the plan's dbid). Anything the parser
        # does not understand makes the verdict NOT_VERIFIED instead of a guess.
        $fidelityRun = Invoke-PerfSqlcmd -Builder $builder -Kind Fidelity -StatementId $label -WorkDir $work
        $fidelity = ConvertFrom-FidelityOutput $fidelityRun.Stdout
        $cacheRows = @($fidelity.Rows)
        $verdict = Get-FidelityVerdict $fidelity $planHashes[0] $minimumExecutions
        $fidelityLines.Add('')
        $fidelityLines.Add("$label : verdict=$verdict ; xml_plan_hash=$($planHashes[0])")
        foreach ($row in $cacheRows) { $fidelityLines.Add("   $($row.Hash) | $($row.Executions) | $($row.First) | $($row.Last)") }
        Write-Host "[$label] done: rows $($first.Rows), fidelity $($verdict.Split(' ')[0])."
    }
    Write-Utf8NoBom (Join-Path $staging "$Phase/$($scenarioItem.Id).stats.txt") (($stats -join "`n") + "`n")
}
Write-Utf8NoBom (Join-Path $staging "$Phase/fidelity.txt") (($fidelityLines -join "`n") + "`n")

# ---- environment.txt (section 5.2, step 6): once, in phase 'before' ----------------------------------------------------
if ($writeEnvironment) {
    $versionRun = Invoke-PerfSqlcmd -Builder $builder -Kind ServerVersion -WorkDir $work
    $cpu = @(Get-CimInstance Win32_Processor)
    $computer = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $dockerInfo = Invoke-ChildProcess -FileName 'docker' -TimeoutSeconds 60 -Arguments @('inspect', '--format', 'image {{.Image}}; config image {{.Config.Image}}; started {{.State.StartedAt}}; status {{.State.Status}}', $script:PerfContainer)
    $dirty = (Get-GitText (@('status', '--porcelain', '--', 'backend/src'))).Text
    $scriptHashes = @('run-sql.ps1', 'measure-api.ps1', 'perf-common.ps1', 'guard-perf-target.ps1') | ForEach-Object {
        $p = Join-Path $script:PerfDir $_
        if (Test-Path -LiteralPath $p) { "  $_ sha256 $((Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash)" }
    }
    $environment = @(
        'T-501 - environment (section 5.2, step 6)',
        "Captured: $stamp local time by run-sql.ps1 in phase '$Phase'. Written once; later phases compare against it, they do not replace it.",
        "Commit (HEAD): $headCommit",
        "backend/src has uncommitted changes: $(if ($dirty) { 'YES' } else { 'no' })",
        "CPU: $(($cpu | ForEach-Object { $_.Name.Trim() }) -join ' + ') ; physical cores $((($cpu | Measure-Object -Property NumberOfCores -Sum).Sum)) ; logical processors $((($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum))",
        "RAM: $([Math]::Round($computer.TotalPhysicalMemory / 1GB, 1)) GB",
        "OS: $($os.Caption) $($os.Version)",
        "PowerShell: $($PSVersionTable.PSVersion)",
        "SQL Server: Docker container '$($script:PerfContainer)' ($($dockerInfo.Stdout.Trim()))",
        'SELECT @@VERSION:',
        ($versionRun.Stdout.Trim() -split "`r?`n" | ForEach-Object { "  $_" }),
        'Scripts:',
        $scriptHashes,
        'SQL files:',
        ($sqlFiles.Keys | Sort-Object | ForEach-Object { "  docs/perf/sql/$_.sql sha256 $($sqlFiles[$_].Sha256) (captured from $($sqlFiles[$_].Commit))" })
    )
    Write-Utf8NoBom (Join-Path $staging $script:PerfEnvironmentFile) ((@($environment | ForEach-Object { $_ }) -join "`n") + "`n")
}

# ---- 8. publish ----------------------------------------------------------------------------------------------------------
# One transaction: the phase files and (create-only) environment.txt are all in place, or none is changed.
Publish-PerfOutput $staging $resultsRootFull $phaseFiles ([bool]$Overwrite) @($(if ($writeEnvironment) { $script:PerfEnvironmentFile }))
[void](Remove-PerfWorkDir $work)
Write-Host "RUN-SQL OK - phase '$Phase': $($phaseFiles.Count) files written under $(Join-Path $resultsRootFull $Phase). The database was only read." -ForegroundColor Green
exit 0
