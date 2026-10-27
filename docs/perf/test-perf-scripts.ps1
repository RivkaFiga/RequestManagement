<#
.SYNOPSIS
    Offline tests for perf-common.ps1, run-sql.ps1, measure-api.ps1 and the tool resolution of guard-perf-target.ps1. They open
    no database connection and start no sqlcmd, docker, dotnet, git, API or Seeder: every case uses a fake password and is
    decided before the first child process of the scripts, and T501_CHILD_LOG (see Invoke-ChildProcess) proves that nothing
    was started. They do start a few powershell.exe children (the scripts under test, small helper scripts) and use the
    temporary folder, a loopback socket on an ephemeral port, and one junction between two folders in the temporary folder.

.DESCRIPTION
    Groups:
      A. helpers, in this process, with Stop-Run replaced by a function that throws: the captured SQL, the approved-hash policy
         and the read-only grammar (including the tamper and bypass cases), the guard approval, the fidelity verdict, tool
         resolution, the API environment, loopback and port ownership, results-root paths, transactional publishing, cleanup;
      B. the scripts as child processes: invalid parameters, the guard's static stops, existing results, results roots, -DryRun;
      C. static checks of the script sources: no migration, Seeder or write statement, the guard before the first connection;
      D. the guarded index procedure (set-index-state.ps1, perf-schema-step.ps1): gates, snapshot, approval code, confirmation,
         the SQL of the removal and restoration generated offline by `dotnet ef migrations script` (no connection), dry runs;
      E. set-index-state.ps1 from start to finish against FAKE docker, sqlcmd and dotnet programs (a small compiled stub in the
         temporary folder, put first on PATH for the child processes only): every stop condition, the normal path stopping before
         the change, and proof that `dotnet ef database update` is never started (the stub would log it and fail it).
    Not covered, because it needs a live SQL Server, Docker, sqlcmd or the API: the shape of real sqlcmd output, the T-SQL of
    the index listing, of the plan-cache query and of the schema-state query (the fakes return text written by hand),
    Invoke-ServerGuard against a real container, the API start and the port-ownership query, and the typing of the confirmation
    sentence at a real console (only the injected-reader function is tested, and a run with redirected output is shown to stop).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$perfDir = $PSScriptRoot
$runSql = Join-Path $perfDir 'run-sql.ps1'
$measureApi = Join-Path $perfDir 'measure-api.ps1'
$commonPath = Join-Path $perfDir 'perf-common.ps1'
$guardPath = Join-Path $perfDir 'guard-perf-target.ps1'
$fake = 'unused-test-password'
$envName = 'ConnectionStrings__RequestManagement'
$savedEnv = [Environment]::GetEnvironmentVariable($envName, 'Process')
$savedLog = [Environment]::GetEnvironmentVariable('T501_CHILD_LOG', 'Process')
$results = New-Object System.Collections.Generic.List[object]
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('t501-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Cs([string]$server, [string]$database) { "Server=$server;Database=$database;User Id=sa;Password=$fake;TrustServerCertificate=True" }
$goodCs = Cs 'localhost,1433' 'RequestManagement_Perf'

function Add-Result([string]$Group, [string]$Name, [bool]$Pass, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Group = $Group; Case = $Name; Pass = $Pass; Detail = $Detail })
}

# Runs a script as a child process with the given connection string (null = variable not set) and returns exit code, output and the child-process log.
function Invoke-Script([string]$Script, [string[]]$Arguments, $ConnectionString) {
    $log = Join-Path $tempRoot ('child-' + [guid]::NewGuid().ToString('N') + '.log')
    if ($null -eq $ConnectionString) { Remove-Item "Env:$envName" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($envName, $ConnectionString, 'Process') }
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $log, 'Process')
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $null, 'Process')
    $started = @()
    if (Test-Path -LiteralPath $log) { $started = @(Get-Content -LiteralPath $log) }
    [pscustomobject]@{ Exit = $exit; Output = $output; Started = $started }
}

function Get-PlanFiles([string]$Output) {
    @(([regex]::Matches($Output, '(?m)^PLAN FILE: (\S+)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object)
}

# Directories are listed by name only: their timestamps change lazily, not because of anything a script did.
function Get-TreeSnapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '(absent)' }
    (Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object { if ($_.PSIsContainer) { "$($_.FullName)|dir" } else { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } } | Sort-Object) -join "`n"
}

# Removes links (junctions, symlinks) below a folder WITHOUT following them, so a later recursive delete cannot leave the folder.
function Remove-LinksIn([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
        try { [IO.Directory]::Delete($item.FullName) } catch { try { [IO.File]::Delete($item.FullName) } catch { } }
    }
}

# The names T-502 must reproduce, written out independently of perf-common.ps1.
$expectedScenarioParts = [ordered]@{ B1a = @('count', 'data'); B1b = @('count', 'data'); B1c = @('count', 'data'); B1d = @('count', 'data'); B1e = @('count', 'data'); B1f = @('count', 'data'); B2 = @('status', 'priority') }
function Get-ExpectedSqlNames([string]$Phase, [string[]]$Only = @()) {
    $names = @("$Phase/indexes.txt", "$Phase/dataset-check.txt", "$Phase/fidelity.txt")
    foreach ($id in $expectedScenarioParts.Keys) {
        if ($Only.Count -gt 0 -and $Only -notcontains $id) { continue }
        $names += "$Phase/$id.stats.txt"
        foreach ($part in $expectedScenarioParts[$id]) { $names += "$Phase/$id.$part.sqlplan" }
    }
    @($names | Sort-Object)
}
function Get-ExpectedApiNames([string]$Phase) { @(@("$Phase/api.csv", "$Phase/api-calls.csv", "$Phase/api-run.txt") | Sort-Object) }

try {
    # ============================================================================================================
    # A. helpers (in this process; Stop-Run throws instead of exiting)
    # ============================================================================================================
    $script:PerfTool = 'TEST'
    . $commonPath
    . (Join-Path $perfDir 'perf-schema-step.ps1')
    function Stop-Run([string]$Code, [string]$Message) { throw [System.InvalidOperationException]::new("STOP[$Code] $Message") }
    function Get-StopCode([scriptblock]$Action) {
        try { [void](& $Action); return 'NONE' }
        catch {
            if ($_.Exception.Message -match '^STOP\[(\w+)\]') { return $matches[1] }
            return "ERROR: $($_.Exception.Message)"
        }
    }
    $goodBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($goodCs)

    # ---- A1. the captured SQL files, the approved hashes ------------------------------------------------------------
    foreach ($id in $expectedScenarioParts.Keys) {
        $file = Read-PerfSqlFile $id $expectedScenarioParts[$id]
        Add-Result 'A' "captured SQL $id parses: parts $($expectedScenarioParts[$id] -join '+'), request and commit header" `
            (($file.Parts.Count -eq $expectedScenarioParts[$id].Count) -and $file.Request -and $file.Commit -and ($file.Sha256.Length -eq 64))
    }
    $b1a = Read-PerfSqlFile 'B1a' @('count', 'data')
    $b1c = Read-PerfSqlFile 'B1c' @('count', 'data')
    $b2 = Read-PerfSqlFile 'B2' @('status', 'priority')
    Add-Result 'A' 'B1a request header is the section 5.1 request' ($b1a.Request -ceq 'status=InProgress&priority=High&createdFrom=2026-07-03T00:00:00Z&createdTo=2026-10-01T00:00:00Z&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20')
    Add-Result 'A' 'B1c request header uses the seed term and status=New' ($b1c.Request -ceq 'search=payroll&status=New&page=1&pageSize=20')
    $b1e = Read-PerfSqlFile 'B1e' @('count', 'data')
    $b1f = Read-PerfSqlFile 'B1f' @('count', 'data')
    Add-Result 'A' 'B1e request header is the handler queue: handler-07, InProgress, default sort' ($b1e.Request -ceq 'assignedTo=handler-07&status=InProgress&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20')
    Add-Result 'A' 'B1f request header is the organization prefix Aurora with the default sort' ($b1f.Request -ceq 'organizationName=Aurora&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20')

    $allFiles = Read-AllPerfSqlFiles @($script:PerfScenarios)
    Add-Result 'A' 'the approved-hash table has 21 entries: 14 statements and 7 requests' ($script:PerfApprovedHashes.Count -eq 21)
    Add-Result 'A' 'all 14 captured statements and 7 requests equal their approved hashes and pass the read-only grammar' ((Get-StopCode { Register-PerfStatements $allFiles }) -eq 'NONE')
    Add-Result 'A' 'a registered statement is the normalised captured text' ((Get-ApprovedStatement 'B1a.count') -ceq (Get-NormalizedSql $b1a.Parts[0].Sql))
    Add-Result 'A' "Invoke-PerfSqlcmd has no parameter that takes SQL text" (-not (Get-Command Invoke-PerfSqlcmd).Parameters.ContainsKey('Sql'))
    Add-Result 'A' 'an unregistered statement id is refused' ((Get-StopCode { Get-ApprovedSql 'StatsRun' 'B9.count' $false }) -eq 'SQL_NOT_APPROVED')
    Add-Result 'A' 'a statement of another scenario part that was never registered is refused' ((Get-StopCode { Get-ApprovedSql 'Fidelity' 'B1a.nothing' $false }) -eq 'SQL_NOT_APPROVED')

    # Tampered files: refused by the hash; and, even if somebody put the tampered text's hash into the table, refused by the grammar.
    $genuine = Get-NormalizedSql $b1a.Parts[0].Sql
    $tampered = [ordered]@{
        'appended :CONNECT'            = "$genuine`n:CONNECT other"
        'appended :!!'                 = "$genuine`n:!! dir"
        'appended USE'                 = "$genuine`nUSE master;"
        'SELECT INTO inside the call'  = $genuine.Replace('SELECT COUNT(*)', 'SELECT COUNT(*) INTO dbo.x')
        'comment appended'             = "$genuine`n-- x"
        'IDENTITY_INSERT before'       = "SET IDENTITY_INSERT dbo.Requests ON;`n$genuine"
        'stacked DROP'                 = "$genuine`nDROP TABLE dbo.Requests;"
        'second EXEC'                  = "$genuine`nEXEC sp_who;"
    }
    foreach ($name in $tampered.Keys) {
        $text = $tampered[$name]
        $fileObject = [pscustomobject]@{ Request = $b1a.Request; Parts = @([pscustomobject]@{ Name = 'count'; Sql = $text }) }
        $byHash = Get-StopCode { Register-PerfStatements @{ 'B1a' = $fileObject } }
        $original = $script:PerfApprovedHashes['B1a.count']
        $script:PerfApprovedHashes['B1a.count'] = Get-Sha256Hex (Get-NormalizedSql $text)
        try { $byGrammar = Get-StopCode { Register-PerfStatements @{ 'B1a' = $fileObject } } } finally { $script:PerfApprovedHashes['B1a.count'] = $original }
        Add-Result 'A' "tampered SQL file ($name): refused by the hash, and by the grammar even with its hash added" (($byHash -eq 'SQL_NOT_APPROVED') -and ($byGrammar -eq 'SQL_NOT_READONLY')) "hash: $byHash; grammar: $byGrammar"
    }
    $changedRequest = [pscustomobject]@{ Request = ($b1a.Request -replace 'page=1', 'page=2'); Parts = @($b1a.Parts) }
    Add-Result 'A' 'a changed -- request: line is refused by its approved hash' ((Get-StopCode { Register-PerfStatements @{ 'B1a' = $changedRequest } }) -eq 'SQL_NOT_APPROVED')
    $unknownScenario = [pscustomobject]@{ Request = 'x=1'; Parts = @([pscustomobject]@{ Name = 'count'; Sql = 'SELECT 1;' }) }
    Add-Result 'A' 'a scenario with no approved hash is refused' ((Get-StopCode { Register-PerfStatements @{ 'B9' = $unknownScenario } }) -eq 'SQL_NOT_APPROVED')

    # ---- A2. needles ---------------------------------------------------------------------------------------------------
    $needle = Get-StatementNeedle $b1a.Parts[0].Sql
    Add-Result 'A' 'needle of B1a.count is the inner statement on one line, without the parameter declaration' `
        ($needle.StartsWith('SELECT COUNT(*) FROM [Requests] AS [r] WHERE') -and -not $needle.Contains("`n") -and -not $needle.Contains('@statuses1 tinyint'))
    Add-Result 'A' 'needle of B2.status is the plain statement without the semicolon' ((Get-StatementNeedle $b2.Parts[0].Sql) -ceq 'SELECT [r].[Status], COUNT(*) FROM [Requests] AS [r] GROUP BY [r].[Status]')
    Add-Result 'A' "needle of B1c.count unescapes the doubled quotes (ESCAPE N'\')" ((Get-StatementNeedle $b1c.Parts[0].Sql).Contains("ESCAPE N'\'"))

    # ---- A3. everything that can be sent is accepted by the grammar -----------------------------------------------------------
    foreach ($key in @($script:PerfApprovedHashes.Keys | Where-Object { $_ -notlike '*.request' } | Sort-Object)) {
        foreach ($xml in @($false, $true)) {
            Add-Result 'A' "StatsRun batch of $key (xml $xml) passes the read-only grammar" ((Get-StopCode { Assert-ReadOnlySql (Get-ApprovedSql 'StatsRun' $key $xml) }) -eq 'NONE')
        }
        Add-Result 'A' "Fidelity query of $key passes the read-only grammar" ((Get-StopCode { Assert-ReadOnlySql (Get-ApprovedSql 'Fidelity' $key $false) }) -eq 'NONE')
    }
    foreach ($kind in @('DatasetCheck', 'IndexListing', 'ServerVersion')) {
        Add-Result 'A' "$kind query passes the read-only grammar" ((Get-StopCode { Assert-ReadOnlySql (Get-ApprovedSql $kind '' $false) }) -eq 'NONE')
    }
    Add-Result 'A' 'the fidelity query escapes a single quote in the needle and still passes the grammar' (((Get-FidelityQuery "x'y").Contains("N'x''y'")) -and ((Get-StopCode { Assert-ReadOnlySql (Get-FidelityQuery "x'y") }) -eq 'NONE'))

    # ---- A4. the grammar refuses everything else ---------------------------------------------------------------------------
    $refused = @(
        ':CONNECT other', "SELECT 1`n:CONNECT other", ':!! dir', "SET NOCOUNT ON;`n:!! del x", ':r c:\x.sql', ':setvar a b', ':ED', "SELECT 1;`n  :out x",
        'USE master', 'SELECT 1; USE master', 'SELECT NEXT VALUE FOR dbo.s', 'SELECT * INTO dbo.x FROM dbo.Requests', 'SELECT 1 INTO #t',
        'SET IDENTITY_INSERT dbo.Requests ON', 'SET ROWCOUNT 5', 'SET LANGUAGE us_english', 'SET TRANSACTION ISOLATION LEVEL SNAPSHOT', 'SET XACT_ABORT ON',
        'SET STATISTICS PROFILE ON', 'SET STATISTICS IO OFF', 'SET NOCOUNT OFF', 'SET QUOTED_IDENTIFIER OFF',
        'SELECT 1 -- x', '/* x */ SELECT 1', 'SELECT "a"', 'SELECT $(x)', "SELECT 1`nGO`nSELECT 2", "SELECT [x'] ; DROP TABLE t; SELECT [y']",
        "EXEC sp_executesql N'SELECT * INTO x FROM y'", "EXEC sp_executesql N'SELECT 1; DROP TABLE x'", "EXEC sp_executesql N'USE master'", 'EXEC sp_executesql @sql',
        "EXEC sp_executesql N'SELECT 1', N'@a int', @a = (SELECT 1)", "EXEC sp_executesql N'SELECT 1', N'@a int; DROP TABLE x', @a = 1", "EXEC sp_executesql N'SELECT 1', @a = 1",
        "SELECT 'abc", "SELECT N'$([char]0x05E9)$([char]0x05DC)$([char]0x05D5)$([char]0x05DD)'", 'SELECT @@SERVERNAME', "SELECT 1; EXEC ('x')", "WAITFOR DELAY '00:00:01'", 'DECLARE @a int',
        'WITH x AS (SELECT 1) SELECT * FROM x', 'DROP TABLE dbo.Requests', 'SELECT 1; DELETE FROM dbo.Requests', "EXEC xp_cmdshell 'dir'", 'EXEC sp_who',
        'UPDATE dbo.Requests SET Status = 1', 'DBCC FREEPROCCACHE', 'ALTER INDEX ALL ON dbo.Requests REBUILD', 'TRUNCATE TABLE dbo.Requests',
        'INSERT INTO dbo.Requests DEFAULT VALUES', 'CREATE INDEX x ON dbo.Requests (Id)', "SELECT * FROM OPENROWSET('SQLNCLI', 'x', 'SELECT 1')", '', ';;',
        "SELECT 1$([char]0)"
    )
    $accepted = New-Object System.Collections.Generic.List[string]
    foreach ($sql in $refused) {
        $code = Get-StopCode { Assert-ReadOnlySql $sql }
        if ($code -ne 'SQL_NOT_READONLY') { $accepted.Add("[$sql] -> $code") }
    }
    Add-Result 'A' "the grammar refuses all $($refused.Count) bypass and write attempts (:CONNECT, :!!, USE, NEXT VALUE FOR, SELECT INTO, session SET, comments, brackets, nested calls, ...)" ($accepted.Count -eq 0) ($accepted -join ' ; ')
    foreach ($named in @(@(':CONNECT other', 'sqlcmd :CONNECT'), @(':!! dir', 'sqlcmd :!!'), @('SELECT 1; USE master', 'USE'), @('SELECT NEXT VALUE FOR dbo.s', 'NEXT VALUE FOR'), @('SELECT * INTO dbo.x FROM dbo.Requests', 'SELECT INTO'), @('SET IDENTITY_INSERT dbo.Requests ON', 'session SET'))) {
        $text = $named[0]
        Add-Result 'A' "explicitly refused: $($named[1])" ((Get-StopCode { Assert-ReadOnlySql $text }) -eq 'SQL_NOT_READONLY')
    }

    # ---- A5. parsers -----------------------------------------------------------------------------------------------------------
    $statsText = @"
Table 'Requests'. Scan count 1, logical reads 23, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.
Table 'Worktable'. Scan count 0, logical reads 0, physical reads 0.

(2 rows affected)

 SQL Server Execution Times:
   CPU time = 15 ms,  elapsed time = 18 ms.
 SQL Server Execution Times:
   CPU time = 16 ms,  elapsed time = 20 ms.
"@
    $withRows = "1|a|b`n2|c|d`n" + $statsText
    $parsed = ConvertFrom-StatsOutput $withRows
    Add-Result 'A' 'STATISTICS parser: logical reads per table' (([long]$parsed.LogicalReads['Requests'] -eq 23) -and ([long]$parsed.LogicalReads['Worktable'] -eq 0))
    Add-Result 'A' 'STATISTICS parser: last Execution Times block, rows, result lines' (($parsed.CpuMs -eq 16) -and ($parsed.ElapsedMs -eq 20) -and ($parsed.Rows -eq 2) -and ($parsed.ResultLineCount -eq 2))
    Add-Result 'A' 'STATISTICS parser: result hash ignores the messages and is stable' ((ConvertFrom-StatsOutput $withRows).ResultSha256 -ceq (ConvertFrom-StatsOutput ("1|a|b`n2|c|d`n" + $statsText.Replace('CPU time = 16', 'CPU time = 99'))).ResultSha256)
    Add-Result 'A' 'STATISTICS parser: a different result gives a different hash' ((ConvertFrom-StatsOutput $withRows).ResultSha256 -cne (ConvertFrom-StatsOutput ("1|a|b`n9|c|d`n" + $statsText)).ResultSha256)
    Add-Result 'A' 'STATISTICS parser: the count value is the first result line' ((ConvertFrom-StatsOutput ("100000`n(1 rows affected)`n" + $statsText)).CountValue -eq 100000)
    $planText = "noise`n<ShowPlanXML xmlns=""http://schemas.microsoft.com/sqlserver/2004/07/showplan"" Version=""1.6""><BatchSequence><Batch><Statements><StmtSimple QueryPlanHash=""0xAB12CD34EF56AB78"" /></Statements></Batch></BatchSequence></ShowPlanXML>`n(1 rows affected)"
    $plans = @(Get-ShowPlans $planText)
    Add-Result 'A' 'plan extraction: one well-formed document and its QueryPlanHash' (($plans.Count -eq 1) -and ([xml]$plans[0]).DocumentElement.Name -eq 'ShowPlanXML' -and (@(Get-PlanHashes $plans[0]))[0] -ceq '0xAB12CD34EF56AB78')
    Add-Result 'A' 'plan extraction: text without a plan gives none' (@(Get-ShowPlans 'no plan here').Count -eq 0)
    Add-Result 'A' 'median of 5 and of 4' (((Get-Median @(5, 1, 3, 2, 4)) -eq 3) -and ((Get-Median @(1, 2, 3, 10)) -eq 2.5))
    $oneToHundred = 1..100 | ForEach-Object { [double]$_ }
    Add-Result 'A' 'nearest-rank p50 and p95 of 1..100 are 50 and 95; of 5 values p95 is the maximum' (((Get-NearestRank $oneToHundred 0.50) -eq 50) -and ((Get-NearestRank $oneToHundred 0.95) -eq 95) -and ((Get-NearestRank @(1.0, 2.0, 3.0, 4.0, 9.0) 0.95) -eq 9))
    Add-Result 'A' 'number format is invariant (dot, 3 decimals)' ((Format-Number 12.3456) -ceq '12.346')

    # ---- A6. the index listing and the phase state -----------------------------------------------------------------------
    $listingText = @"
Requests|PK_Requests|CLUSTERED|Id ASC||100000|2254
Requests|IX_Requests_CreatedAt_Id|NONCLUSTERED|CreatedAt DESC, Id DESC||100000|622
Requests|IX_Requests_Status_CreatedAt|NONCLUSTERED|Status ASC, CreatedAt DESC|Priority|100000|657
Requests|IX_Requests_AssignedTo_Status_CreatedAt|NONCLUSTERED|AssignedTo ASC, Status ASC, CreatedAt DESC||100000|1041
Requests|IX_Requests_OrganizationName_CreatedAt|NONCLUSTERED|OrganizationName ASC, CreatedAt DESC||100000|1411
Requests|IX_Requests_Priority_Status|NONCLUSTERED|Priority ASC, Status ASC||100000|344
RequestStatusHistory|PK_RequestStatusHistory|CLUSTERED|Id ASC||0|0
"@
    $withIndexes = @(ConvertFrom-IndexListing $listingText)
    $withoutIndexes = @($withIndexes | Where-Object { $_.Index -notlike 'IX_Requests_*' })
    $withoutOne = @($withIndexes | Where-Object { $_.Index -ne 'IX_Requests_Priority_Status' })
    Add-Result 'A' 'index listing parser reads table, keys, included columns, rows and pages' (($withIndexes.Count -eq 7) -and ($withIndexes[2].Included -ceq 'Priority') -and ($withIndexes[2].Keys -ceq 'Status ASC, CreatedAt DESC') -and ($withIndexes[1].Pages -eq 622))
    Add-Result 'A' "phase state accepts 'after' with all indexes and 'before' without them" (((Get-StopCode { Assert-PhaseIndexState 'after' $withIndexes }) -eq 'NONE') -and ((Get-StopCode { Assert-PhaseIndexState 'before' $withoutIndexes }) -eq 'NONE'))
    Add-Result 'A' "phase state refuses 'before' with indexes and 'after' with one missing" (((Get-StopCode { Assert-PhaseIndexState 'before' $withIndexes }) -eq 'PHASE_STATE_MISMATCH') -and ((Get-StopCode { Assert-PhaseIndexState 'after' $withoutOne }) -eq 'PHASE_STATE_MISMATCH'))

    # ---- A7. output names (T-502 compatibility): deviation A, section 5.3 --------------------------------------------------------
    foreach ($phase in @('before', 'after')) {
        $actual = @(Get-SqlOutputFiles $phase @($script:PerfScenarios) | Sort-Object)
        Add-Result 'A' "run-sql output names for '$phase' equal the T-502 names (stats per scenario, sqlplan per statement)" (($actual -join ',') -ceq ((Get-ExpectedSqlNames $phase) -join ','))
        $actualApi = @(Get-ApiOutputFiles $phase | Sort-Object)
        Add-Result 'A' "measure-api output names for '$phase' are api.csv, api-calls.csv, api-run.txt" (($actualApi -join ',') -ceq ((Get-ExpectedApiNames $phase) -join ','))
    }
    Add-Result 'A' 'no .sqlplan is named per scenario only (deviation A)' (@(Get-SqlOutputFiles 'before' @($script:PerfScenarios) | Where-Object { $_ -match '\.sqlplan$' -and ($_ -split '\.').Count -ne 3 }).Count -eq 0)

    # ---- A8. M2: the guard's approval is enforced inside the functions that connect ------------------------------------------------
    $script:PerfGuardApproval = $null
    [Environment]::SetEnvironmentVariable($envName, $goodCs, 'Process')
    $probeLog = Join-Path $tempRoot 'approval.log'
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $probeLog, 'Process')
    Add-Result 'A' 'without an approval, Assert-GuardApproved stops' ((Get-StopCode { Assert-GuardApproved }) -eq 'GUARD_NOT_APPROVED')
    Add-Result 'A' 'without an approval, Invoke-PerfSqlcmd stops before building SQL or starting anything' ((Get-StopCode { Invoke-PerfSqlcmd -Builder $goodBuilder -Kind IndexListing -WorkDir $tempRoot }) -eq 'GUARD_NOT_APPROVED')
    foreach ($tool in @('sqlcmd', 'sqlcmd.exe', 'dotnet', 'C:\nowhere\sqlcmd.exe')) {
        Add-Result 'A' "without an approval, Invoke-ChildProcess refuses '$tool' before resolving or starting it" ((Get-StopCode { Invoke-ChildProcess -FileName $tool -Arguments @('-?') }) -eq 'GUARD_NOT_APPROVED')
    }
    Add-Result 'A' 'none of those attempts launched anything (T501_CHILD_LOG not written)' (-not (Test-Path -LiteralPath $probeLog))
    $script:PerfGuardApproval = [pscustomobject]@{ Server = $goodBuilder.DataSource; Database = 'RequestManagement_Perf'; ConnectionHash = (Get-PerfConnectionHash) }
    Add-Result 'A' 'an approval for this target and this connection string is accepted' ((Get-StopCode { Assert-GuardApproved $goodBuilder }) -eq 'NONE')
    [Environment]::SetEnvironmentVariable($envName, "$goodCs;Application Name=changed", 'Process')
    Add-Result 'A' 'the approval is void once the connection string in the environment changes' ((Get-StopCode { Assert-GuardApproved }) -eq 'GUARD_NOT_APPROVED')
    [Environment]::SetEnvironmentVariable($envName, $goodCs, 'Process')
    $otherServer = New-Object System.Data.SqlClient.SqlConnectionStringBuilder((Cs '127.0.0.1,1433' 'RequestManagement_Perf'))
    Add-Result 'A' 'the approval does not cover another server spelling' ((Get-StopCode { Assert-GuardApproved $otherServer }) -eq 'GUARD_NOT_APPROVED')
    $script:PerfGuardApproval = [pscustomobject]@{ Server = $goodBuilder.DataSource; Database = 'RequestManagement'; ConnectionHash = (Get-PerfConnectionHash) }
    Add-Result 'A' 'an approval for another database is refused' ((Get-StopCode { Assert-GuardApproved }) -eq 'GUARD_NOT_APPROVED')
    $script:PerfGuardApproval = $null
    Add-Result 'A' 'a stale approval cannot survive: after clearing it, the next connection is refused again' ((Get-StopCode { Invoke-PerfSqlcmd -Builder $goodBuilder -Kind DatasetCheck -WorkDir $tempRoot }) -eq 'GUARD_NOT_APPROVED')
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $null, 'Process')

    # ---- A9. M3: fidelity filtered by the database of the plan; unprovable means NOT_VERIFIED ---------------------------------------
    $fidelityQuery = Get-FidelityQuery 'SELECT 1'
    Add-Result 'A' "the plan-cache query filters on the plan's dbid = DB_ID() before it looks at statement text" (
        $fidelityQuery.Contains("sys.dm_exec_plan_attributes(qs.plan_handle)") -and $fidelityQuery.Contains("pa.attribute = N'dbid'") -and $fidelityQuery.Contains('pdb.plan_dbid = DB_ID()') -and
        ($fidelityQuery.IndexOf('pdb.plan_dbid = DB_ID()') -lt $fidelityQuery.IndexOf("CHARINDEX(N'SELECT 1'")))
    $hash = '0xAB12CD34EF56AB78'
    $okRow = "$hash|7|2026-10-25T10:00:00.000|2026-10-25T10:01:00.000"
    Add-Result 'A' 'verdict STABLE: one hash, equal to the plan, enough executions (also with different letter case)' (((Get-FidelityVerdict (ConvertFrom-FidelityOutput $okRow) $hash 7) -ceq 'STABLE') -and ((Get-FidelityVerdict (ConvertFrom-FidelityOutput $okRow) $hash.ToLowerInvariant() 7) -ceq 'STABLE'))
    Add-Result 'A' 'verdict NOT_VERIFIED: too few executions' ((Get-FidelityVerdict (ConvertFrom-FidelityOutput "$hash|6|a|b") $hash 7).StartsWith('NOT_VERIFIED'))
    Add-Result 'A' 'verdict PLAN_UNSTABLE: two hashes in the cache' ((Get-FidelityVerdict (ConvertFrom-FidelityOutput "$okRow`n0xFFFFFFFFFFFFFFFF|3|a|b") $hash 7).StartsWith('PLAN_UNSTABLE'))
    Add-Result 'A' 'verdict PLAN_UNSTABLE: the cached hash is not the saved plan' ((Get-FidelityVerdict (ConvertFrom-FidelityOutput '0x1111111111111111|9|a|b') $hash 7).StartsWith('PLAN_UNSTABLE'))
    Add-Result 'A' 'verdict NOT_VERIFIED: no row (nothing in the cache for this database)' ((Get-FidelityVerdict (ConvertFrom-FidelityOutput '') $hash 7).StartsWith('NOT_VERIFIED'))
    Add-Result 'A' 'verdict NOT_VERIFIED: a NULL hash line, even next to a good row' ((Get-FidelityVerdict (ConvertFrom-FidelityOutput "$okRow`nNULL") $hash 7).StartsWith('NOT_VERIFIED'))
    Add-Result 'A' 'verdict NOT_VERIFIED: an error message instead of rows' ((Get-FidelityVerdict (ConvertFrom-FidelityOutput "Msg 208, Level 16, State 1`nInvalid object name") $hash 7).StartsWith('NOT_VERIFIED'))

    # ---- A10. L2: tools by full path, and only the allowed ones ---------------------------------------------------------------------
    $powershellPath = Resolve-PerfTool 'powershell.exe'
    Add-Result 'A' 'powershell.exe resolves to an absolute path under $PSHOME' ([IO.Path]::IsPathRooted($powershellPath) -and $powershellPath.StartsWith($PSHOME, [StringComparison]::OrdinalIgnoreCase))
    Add-Result 'A' 'a program that is not on the allowed list is refused' ((Get-StopCode { Resolve-PerfTool 'notepad.exe' }) -eq 'TOOL_NOT_ALLOWED')
    Add-Result 'A' 'a rooted path that Resolve-PerfTool did not produce is refused' ((Get-StopCode { Invoke-ChildProcess -FileName (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/c', 'exit') }) -eq 'TOOL_NOT_ALLOWED')
    Add-Result 'A' 'tool paths: relative, UNC, in the repository and in the current folder are refused; $PSHOME is accepted' (
        -not (Test-PerfToolPathAllowed 'sqlcmd.exe') -and -not (Test-PerfToolPathAllowed '\\server\share\sqlcmd.exe') -and
        -not (Test-PerfToolPathAllowed (Join-Path $script:PerfRepo 'sqlcmd.exe')) -and -not (Test-PerfToolPathAllowed (Join-Path (Get-Location).ProviderPath 'git.exe')) -and
        (Test-PerfToolPathAllowed $powershellPath))
    Add-Result 'A' 'the guard finds docker/sqlcmd by full path too (Get-GuardTool): a real tool is rooted, a missing one is $null' (([IO.Path]::IsPathRooted((Get-GuardTool 'powershell'))) -and ($null -eq (Get-GuardTool 'no-such-tool-t501')))
    $guardText = Get-Content -LiteralPath $guardPath -Raw
    Add-Result 'A' 'the guard no longer starts docker or sqlcmd by bare name' (($guardText -notmatch '(?m)&\s+docker\b') -and ($guardText -notmatch '(?m)&\s+sqlcmd\b') -and $guardText.Contains('& $dockerPath') -and $guardText.Contains('& $sqlcmdPath'))

    # ---- A11. L4: the API's environment and the checked connection string -------------------------------------------------------------
    $sampleEnvironment = @{
        'ASPNETCORE_HTTPS_PORT' = '1'; 'ASPNETCORE_URLS' = 'x'; 'Logging__LogLevel__Default' = 'Debug'; 'SummaryCache__ExpirationSeconds' = '1'; 'SummaryCache__Enabled' = 'false'
        'ConnectionStrings__Other' = 'x'; 'ConnectionStrings__RequestManagement' = 'x'; 'Kestrel__Endpoints__Http__Url' = 'x'; 'DOTNET_gcServer' = '1'; 'DOTNET_ENVIRONMENT' = 'Development'
        'DOTNET_ROOT' = 'C:\dotnet'; 'DOTNET_CLI_HOME' = 'C:\h'; 'DOTNET_NOLOGO' = '1'; 'COMPlus_gcServer' = '1'; 'AllowedHosts' = '*'; 'Urls' = 'x'; 'APPSETTING_x' = '1'
        'PATH' = 'C:\x'; 'TEMP' = 'C:\t'; 'SystemRoot' = 'C:\Windows'; 'USERPROFILE' = 'C:\u'; 'T501_CHILD_LOG' = 'x'
    }
    $removals = @(Get-PerfApiEnvironmentRemovals $sampleEnvironment)
    $mustGo = @('ASPNETCORE_HTTPS_PORT', 'ASPNETCORE_URLS', 'Logging__LogLevel__Default', 'SummaryCache__ExpirationSeconds', 'SummaryCache__Enabled', 'ConnectionStrings__Other', 'ConnectionStrings__RequestManagement', 'Kestrel__Endpoints__Http__Url', 'DOTNET_gcServer', 'DOTNET_ENVIRONMENT', 'COMPlus_gcServer', 'AllowedHosts', 'Urls', 'APPSETTING_x')
    $mustStay = @('DOTNET_ROOT', 'DOTNET_CLI_HOME', 'DOTNET_NOLOGO', 'PATH', 'TEMP', 'SystemRoot', 'USERPROFILE', 'T501_CHILD_LOG')
    Add-Result 'A' 'settings that change the API or its measurement are removed from its environment' (@($mustGo | Where-Object { $removals -notcontains $_ }).Count -eq 0) "missing: $(@($mustGo | Where-Object { $removals -notcontains $_ }) -join ',')"
    Add-Result 'A' 'PATH, TEMP, SystemRoot, DOTNET_ROOT and the like are kept' (@($mustStay | Where-Object { $removals -contains $_ }).Count -eq 0) "removed: $(@($mustStay | Where-Object { $removals -contains $_ }) -join ',')"
    $aliasBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder("Data Source=localhost,1433;Initial Catalog=RequestManagement_Perf;uid=sa;pwd=$fake;TrustServerCertificate=True")
    Add-Result 'A' 'the normalised connection string passes the target check and spells the keywords canonically' ((@(Get-PerfTargetFailures -ConnectionString $aliasBuilder.ConnectionString).Count -eq 0) -and $aliasBuilder.ConnectionString.Contains('Initial Catalog=RequestManagement_Perf') -and -not $aliasBuilder.ConnectionString.Contains('uid='))

    # ---- A12. L5: loopback only, nobody else's listener --------------------------------------------------------------------------
    Add-Result 'A' 'only http://127.0.0.1:<port> is a valid API address' (
        (Test-PerfLoopbackUrl 'http://127.0.0.1:5190' 5190) -and (Test-PerfLoopbackUrl 'http://127.0.0.1:5190/api/requests?a=b' 5190) -and
        -not (Test-PerfLoopbackUrl 'http://localhost:5190' 5190) -and -not (Test-PerfLoopbackUrl 'https://127.0.0.1:5190' 5190) -and -not (Test-PerfLoopbackUrl 'http://127.0.0.1:5191' 5190) -and
        -not (Test-PerfLoopbackUrl 'http://127.0.0.2:5190' 5190) -and -not (Test-PerfLoopbackUrl 'http://a@127.0.0.1:5190' 5190) -and -not (Test-PerfLoopbackUrl 'http://127.0.0.1.example.com:5190' 5190) -and
        -not (Test-PerfLoopbackUrl 'http://[::1]:5190' 5190) -and -not (Test-PerfLoopbackUrl 'not a url' 5190))
    $own = [pscustomobject]@{ OwningProcess = 4242; LocalAddress = '127.0.0.1' }
    Add-Result 'A' 'listener ownership: only our process on 127.0.0.1 counts; none, another pid, a wildcard address or a mixed set do not' (
        (Test-ListenerOwnership @($own) 4242) -and -not (Test-ListenerOwnership @() 4242) -and -not (Test-ListenerOwnership @($own) 1) -and
        -not (Test-ListenerOwnership @([pscustomobject]@{ OwningProcess = 4242; LocalAddress = '0.0.0.0' }) 4242) -and
        -not (Test-ListenerOwnership @($own, [pscustomobject]@{ OwningProcess = 9; LocalAddress = '127.0.0.1' }) 4242))
    $loopbackListener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $wildcardListener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Any, 0)
    try {
        $loopbackListener.Start(); $wildcardListener.Start()
        $loopbackPort = $loopbackListener.LocalEndpoint.Port
        $wildcardPort = $wildcardListener.LocalEndpoint.Port
        Add-Result 'A' 'a port held by another listener on 127.0.0.1 is not free' (-not (Test-PerfPortFree $loopbackPort))
        Add-Result 'A' 'a port held by a wildcard listener is not free' (-not (Test-PerfPortFree $wildcardPort))
    }
    finally { $loopbackListener.Stop(); $wildcardListener.Stop() }
    Add-Result 'A' 'a port that nobody holds is free' (Test-PerfPortFree $loopbackPort)

    # ---- A13. L8: the results root --------------------------------------------------------------------------------------------------
    $officialResults = Join-Path $perfDir 'results'
    Add-Result 'A' 'the official folder is recognised in another case' (Test-PerfDefaultResults ($officialResults.ToUpperInvariant()))
    Add-Result 'A' 'the official folder is recognised through .. components' (Test-PerfDefaultResults (Join-Path $perfDir 'sql\..\results'))
    $shortPath = $null
    try { $shortPath = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($officialResults).ShortPath } catch { }
    if ($shortPath -and $shortPath -ine $officialResults) {
        Add-Result 'A' "the official folder is recognised through its 8.3 name ($shortPath)" (Test-PerfDefaultResults $shortPath)
        Add-Result 'A' 'a subset run into the 8.3 spelling of the official folder is still a default-root run' ((Resolve-PerfResultsRoot $shortPath) -ceq $script:PerfDefaultResults)
    }
    else { Add-Result 'A' 'the official folder through its 8.3 name (this volume has no short name for it; the case is skipped)' $true }
    Add-Result 'A' 'a root inside docs/perf/results is refused' ((Get-StopCode { Resolve-PerfResultsRoot (Join-Path $officialResults 'before') }) -eq 'RESULTS_ROOT_INSIDE_OFFICIAL')
    Add-Result 'A' 'UNC, wildcard and stream roots are refused' (
        ((Get-StopCode { Resolve-PerfResultsRoot '\\server\share\x' }) -eq 'RESULTS_ROOT_INVALID') -and ((Get-StopCode { Resolve-PerfResultsRoot (Join-Path $tempRoot 'a*b') }) -eq 'RESULTS_ROOT_INVALID') -and
        ((Get-StopCode { Resolve-PerfResultsRoot (Join-Path $tempRoot 'a:stream') }) -eq 'RESULTS_ROOT_INVALID'))
    Add-Result 'A' 'a plain folder under the temp folder is accepted and spelled canonically' ((Get-StopCode { Resolve-PerfResultsRoot (Join-Path $tempRoot 'plain') }) -eq 'NONE')
    $linkTarget = Join-Path $tempRoot 'junction-target'
    $link = Join-Path $tempRoot 'junction-link'
    New-Item -ItemType Directory -Path (Join-Path $linkTarget 'child') -Force | Out-Null
    try {
        New-Item -ItemType Junction -Path $link -Target $linkTarget | Out-Null
        Add-Result 'A' 'a root that is a junction is refused' ((Get-StopCode { Resolve-PerfResultsRoot $link }) -eq 'RESULTS_ROOT_REPARSE')
        Add-Result 'A' 'a root below a junction (existing or not) is refused' (((Get-StopCode { Resolve-PerfResultsRoot (Join-Path $link 'child') }) -eq 'RESULTS_ROOT_REPARSE') -and ((Get-StopCode { Resolve-PerfResultsRoot (Join-Path $link 'new\deeper') }) -eq 'RESULTS_ROOT_REPARSE'))
        $r = Invoke-Script $runSql @('-Phase', 'before', '-Scenario', 'B2', '-ResultsRoot', (Join-Path $link 'x'), '-DryRun') $goodCs
        Add-Result 'A' 'run-sql stops on a results root behind a junction, before it plans or starts anything' (($r.Exit -eq 1) -and $r.Output.Contains('[RESULTS_ROOT_REPARSE]') -and ($r.Started.Count -eq 0))
    }
    finally { Remove-LinksIn $tempRoot }
    Add-Result 'A' 'the junction was removed as a link and its target folder is intact' ((-not (Test-Path -LiteralPath $link)) -and (Test-Path -LiteralPath (Join-Path $linkTarget 'child')))

    # ---- A14. L3: publishing is a transaction ---------------------------------------------------------------------------------------------
    $stage = Join-Path $tempRoot 'stage'
    $root = Join-Path $tempRoot 'publish-root'
    New-Item -ItemType Directory -Path (Join-Path $stage 'before') -Force | Out-Null
    foreach ($n in @('one', 'two', 'three')) { Set-Content -LiteralPath (Join-Path $stage "before\$n.txt") -Value "new-$n" -Encoding ASCII }
    Set-Content -LiteralPath (Join-Path $stage 'environment.txt') -Value 'env' -Encoding ASCII
    $files = @('before/one.txt', 'before/two.txt', 'before/three.txt')
    Add-Result 'A' 'publish into an empty root creates the folders and places every file, with no leftovers' (
        ((Get-StopCode { Publish-PerfOutput $stage $root $files $false @('environment.txt') }) -eq 'NONE') -and
        ((Get-Content -LiteralPath (Join-Path $root 'before\two.txt') -Raw).Trim() -ceq 'new-two') -and (Test-Path -LiteralPath (Join-Path $root 'environment.txt')) -and
        (@(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Name -like '*.t501-*' }).Count -eq 0))
    Add-Result 'A' 'a second publish without -Overwrite is refused and changes nothing' (
        ((Get-StopCode { Publish-PerfOutput $stage $root $files $false }) -eq 'RESULTS_EXIST') -and ((Get-StopCode { Publish-PerfOutput $stage $root @() $false @('environment.txt') }) -eq 'RESULTS_EXIST'))
    foreach ($n in @('one', 'two', 'three')) { Set-Content -LiteralPath (Join-Path $stage "before\$n.txt") -Value "newer-$n" -Encoding ASCII }
    Add-Result 'A' 'publish with -Overwrite replaces the files and removes the backups' (
        ((Get-StopCode { Publish-PerfOutput $stage $root $files $true }) -eq 'NONE') -and ((Get-Content -LiteralPath (Join-Path $root 'before\one.txt') -Raw).Trim() -ceq 'newer-one') -and
        (@(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Name -like '*.t501-*' }).Count -eq 0))
    Set-Content -LiteralPath (Join-Path $root 'before\one.txt.t501-old') -Value 'left' -Encoding ASCII
    Add-Result 'A' 'a backup left by an interrupted publish stops the next one' ((Get-StopCode { Publish-PerfOutput $stage $root $files $true }) -eq 'PUBLISH_LEFTOVER')
    Remove-Item -LiteralPath (Join-Path $root 'before\one.txt.t501-old') -Force

    # A failure in the middle (a file that is held open and cannot be renamed) must roll everything back. The child process
    # publishes; this process holds the lock.
    $failRoot = Join-Path $tempRoot 'publish-fail'
    New-Item -ItemType Directory -Path (Join-Path $failRoot 'before') -Force | Out-Null
    foreach ($n in @('one', 'two', 'three')) { Set-Content -LiteralPath (Join-Path $failRoot "before\$n.txt") -Value "old-$n" -Encoding ASCII }
    $publishChild = Join-Path $tempRoot 'publish-child.ps1'
    Set-Content -LiteralPath $publishChild -Encoding UTF8 -Value @"
param([string]`$Stage, [string]`$Root)
`$script:PerfTool = 'CHILD'
. '$commonPath'
Publish-PerfOutput `$Stage `$Root @('before/one.txt', 'before/two.txt', 'before/three.txt') `$true @('environment.txt')
'DONE'
"@
    $lock = [IO.File]::Open((Join-Path $failRoot 'before\two.txt'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $r = Invoke-Script $publishChild @($stage, $failRoot) $null } finally { $lock.Dispose() }
    $contents = @('one', 'two', 'three') | ForEach-Object { (Get-Content -LiteralPath (Join-Path $failRoot "before\$_.txt") -Raw).Trim() }
    Add-Result 'A' 'a failure in the middle of a publish exits 1 with PUBLISH_FAILED and rolls back' (($r.Exit -eq 1) -and $r.Output.Contains('[PUBLISH_FAILED]') -and -not $r.Output.Contains('DONE')) $r.Output
    Add-Result 'A' 'after the rollback every old file is intact, environment.txt was not created and no *.t501-* file is left' (
        (($contents -join ',') -ceq 'old-one,old-two,old-three') -and -not (Test-Path -LiteralPath (Join-Path $failRoot 'environment.txt')) -and
        (@(Get-ChildItem -LiteralPath $failRoot -Recurse -Force | Where-Object { $_.Name -like '*.t501-*' }).Count -eq 0)) ($contents -join ',')

    # ---- A15. L6: temporary folders are removed, also after a failure -----------------------------------------------------------------------
    $trapChild = Join-Path $tempRoot 'trap-child.ps1'
    Set-Content -LiteralPath $trapChild -Encoding UTF8 -Value @"
`$script:PerfTool = 'CHILD'
. '$commonPath'
trap { Invoke-PerfFailureCleanup; break }
`$d = New-PerfWorkDir
Set-Content -LiteralPath (Join-Path `$d 'x.txt') -Value 'x'
Write-Host "DIR=`$d"
throw 'boom'
"@
    $stopChild = Join-Path $tempRoot 'stop-child.ps1'
    Set-Content -LiteralPath $stopChild -Encoding UTF8 -Value @"
param([switch]`$Keep)
`$script:PerfTool = 'CHILD'
. '$commonPath'
`$script:PerfKeepOnFailure = [bool]`$Keep
`$d = New-PerfWorkDir
Set-Content -LiteralPath (Join-Path `$d 'x.txt') -Value 'x'
Write-Host "DIR=`$d"
Stop-Run 'TEST' 'stopping on purpose'
"@
    foreach ($case in @(@('an unexpected error (trap)', $trapChild, @(), $false), @('Stop-Run', $stopChild, @(), $false), @('Stop-Run with -KeepWorkOnFailure', $stopChild, @('-Keep'), $true))) {
        $r = Invoke-Script $case[1] $case[2] $null
        $dir = if ($r.Output -match '(?m)^DIR=(.+?)\s*$') { $matches[1] } else { $null }
        $exists = $dir -and (Test-Path -LiteralPath $dir)
        Add-Result 'A' "temporary folder after $($case[0]): $(if ($case[3]) { 'kept on request' } else { 'removed' })" (($r.Exit -ne 0) -and $dir -and ($exists -eq $case[3])) "dir=$dir exists=$exists"
        if ($exists) { [void](Remove-PerfWorkDir $dir) }
    }
    Add-Result 'A' 'Remove-PerfWorkDir refuses a folder that is not a t501-perf-* folder directly in the temp folder' ((-not (Remove-PerfWorkDir $tempRoot)) -and (Test-Path -LiteralPath $tempRoot) -and (-not (Remove-PerfWorkDir $env:SystemRoot)))
    $guarded = Join-Path ([IO.Path]::GetTempPath()) ('t501-perf-test-' + [guid]::NewGuid().ToString('N'))
    $guardedTarget = Join-Path $tempRoot 'guarded-target'
    New-Item -ItemType Directory -Path $guarded, $guardedTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $guardedTarget 'keep.txt') -Value 'keep' -Encoding ASCII
    try {
        New-Item -ItemType Junction -Path (Join-Path $guarded 'link') -Target $guardedTarget | Out-Null
        $refusedWithLink = -not (Remove-PerfWorkDir $guarded)
        Add-Result 'A' 'Remove-PerfWorkDir refuses a folder that contains a junction and leaves its target alone' ($refusedWithLink -and (Test-Path -LiteralPath (Join-Path $guardedTarget 'keep.txt')))
    }
    finally { Remove-LinksIn $guarded; Remove-Item -LiteralPath $guarded -Recurse -Force -ErrorAction SilentlyContinue }
    $plain = Join-Path ([IO.Path]::GetTempPath()) ('t501-perf-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $plain | Out-Null
    Set-Content -LiteralPath (Join-Path $plain 'a.txt') -Value 'a' -Encoding ASCII
    Add-Result 'A' 'Remove-PerfWorkDir removes an ordinary t501-perf-* folder' ((Remove-PerfWorkDir $plain) -and -not (Test-Path -LiteralPath $plain))

    # ---- A16. control: a launch IS logged (so an empty log in group B means something) ---------------------------------------------------------
    $controlLog = Join-Path $tempRoot 'control.log'
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $controlLog, 'Process')
    [void](Invoke-ChildProcess -FileName 'powershell.exe' -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -TimeoutSeconds 60)
    Add-Result 'A' 'Invoke-ChildProcess logs a launch (by full path) to T501_CHILD_LOG (control for the dry-run proof)' ((Test-Path -LiteralPath $controlLog) -and (@(Get-Content -LiteralPath $controlLog).Count -eq 1) -and ((Get-Content -LiteralPath $controlLog -Raw).StartsWith($powershellPath)))
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $null, 'Process')
    [Environment]::SetEnvironmentVariable($envName, $null, 'Process')

    # ---- A17. a timeout ends the whole process tree (a tool's worker child must not go on, e.g. an EF update) ----------------------------------------
    $grandchildPidFile = Join-Path $tempRoot 'grandchild.pid'
    $grandchildScript = Join-Path $tempRoot 'grandchild.ps1'
    $childScript = Join-Path $tempRoot 'child.ps1'
    [IO.File]::WriteAllText($grandchildScript, "Set-Content -LiteralPath '$grandchildPidFile' -Value `$PID -Encoding ASCII`nStart-Sleep -Seconds 120`n", (New-Object System.Text.UTF8Encoding($true)))
    $childBody = @'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -NonInteractive -File "{G}"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[void][System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 120
'@
    [IO.File]::WriteAllText($childScript, $childBody.Replace('{G}', $grandchildScript), (New-Object System.Text.UTF8Encoding($true)))
    $timed = Invoke-ChildProcess -FileName 'powershell.exe' -Arguments @('-NoProfile', '-NonInteractive', '-File', $childScript) -TimeoutSeconds 8
    Start-Sleep -Seconds 2
    $grandchildPid = if (Test-Path -LiteralPath $grandchildPidFile) { [int](Get-Content -LiteralPath $grandchildPidFile -Raw).Trim() } else { 0 }
    $grandchildAlive = ($grandchildPid -gt 0) -and ($null -ne (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue))
    if ($grandchildAlive) { Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue }
    Add-Result 'A' 'a timed-out child is reported as timed out, and its grandchild (which had started: it wrote its PID) is gone too' ($timed.TimedOut -and ($grandchildPid -gt 0) -and -not $grandchildAlive) "timedout=$($timed.TimedOut) grandchild=$grandchildPid alive=$grandchildAlive"

    # ============================================================================================================
    # D. the guarded index procedure: set-index-state.ps1 and perf-schema-step.ps1 (everything here is offline)
    # ============================================================================================================
    $setIndexState = Join-Path $perfDir 'set-index-state.ps1'
    $opts = 'fill=0|padded=0|ignoredup=0|rowlocks=1|pagelocks=1|filter=0|seqkey=0|disabled=0'
    function New-IndexLine([string]$table, [string]$name, [string]$type, [int]$u, [int]$pk, [string]$keys, [string]$include) { "index|$table|$name|$type|unique=$u|pk=$pk|$opts|keys=$keys|include=$include|compression=NONE" }
    # Written out by hand from the live state of 2026-10-26 (and results/dataset.txt), independent of the library's constants.
    $withLines = @(
        'target|db=RequestManagement_Perf|marker=1|state=ONLINE|readonly=0|collation=SQL_Latin1_General_CP1_CI_AS',
        'dataset|rows=100000|checksum=-1953119262',
        'by_status|1|19831', 'by_status|2|29844', 'by_status|3|14982', 'by_status|4|35343',
        'by_priority|1|40005', 'by_priority|2|45166', 'by_priority|3|14829',
        'bounds|min_id=1|max_id=100000|min_created=2024-10-01 00:12:49.685|max_created=2026-09-30 23:45:30.586|history_rows=0',
        'migration|20261020183000_InitialCreate|10.0.13', 'migration|20261020183100_AddQueryIndexes|10.0.13',
        (New-IndexLine 'Requests' 'PK_Requests' 'CLUSTERED' 1 1 'Id ASC' ''),
        (New-IndexLine 'Requests' 'IX_Requests_AssignedTo_Status_CreatedAt' 'NONCLUSTERED' 0 0 'AssignedTo ASC, Status ASC, CreatedAt DESC' ''),
        (New-IndexLine 'Requests' 'IX_Requests_CreatedAt_Id' 'NONCLUSTERED' 0 0 'CreatedAt DESC, Id DESC' ''),
        (New-IndexLine 'Requests' 'IX_Requests_OrganizationName_CreatedAt' 'NONCLUSTERED' 0 0 'OrganizationName ASC, CreatedAt DESC' ''),
        (New-IndexLine 'Requests' 'IX_Requests_Priority_Status' 'NONCLUSTERED' 0 0 'Priority ASC, Status ASC' ''),
        (New-IndexLine 'Requests' 'IX_Requests_Status_CreatedAt' 'NONCLUSTERED' 0 0 'Status ASC, CreatedAt DESC' 'Priority'),
        (New-IndexLine 'RequestStatusHistory' 'PK_RequestStatusHistory' 'CLUSTERED' 1 1 'Id ASC' ''),
        (New-IndexLine 'RequestStatusHistory' 'IX_RequestStatusHistory_RequestId_ChangedAt' 'NONCLUSTERED' 0 0 'RequestId ASC, ChangedAt DESC' ''),
        (New-IndexLine '__EFMigrationsHistory' 'PK___EFMigrationsHistory' 'CLUSTERED' 1 1 'MigrationId ASC' ''),
        'constraint|Requests|CK_Requests_Priority', 'constraint|Requests|CK_Requests_Status', 'constraint|Requests|CK_Requests_UpdatedAt_NotBeforeCreatedAt',
        'constraint|RequestStatusHistory|CK_RequestStatusHistory_NewStatus', 'constraint|RequestStatusHistory|CK_RequestStatusHistory_PreviousStatus', 'constraint|RequestStatusHistory|CK_RequestStatusHistory_StatusChanged',
        'fk|RequestStatusHistory|FK_RequestStatusHistory_Requests_RequestId|delete=NO_ACTION',
        'pages|Requests|PK_Requests|2254', 'pages|Requests|IX_Requests_CreatedAt_Id|622',
        'sessions|0'
    )
    function Edit-Lines([string[]]$Lines, [string]$Like, [string]$Old, [string]$New) { @($Lines | ForEach-Object { if ($_ -like $Like) { $_.Replace($Old, $New) } else { $_ } }) }
    function Drop-Lines([string[]]$Lines, [string]$Like) { @($Lines | Where-Object { $_ -notlike $Like }) }
    function ConvertTo-State([string[]]$Lines) { ConvertFrom-SchemaState ($Lines -join "`n") }
    $withoutLines = Drop-Lines (Drop-Lines $withLines 'index|Requests|IX_Requests_*') 'migration|20261020183100_AddQueryIndexes|*'
    $withState = ConvertTo-State $withLines
    $withoutState = ConvertTo-State $withoutLines
    $snapshotState = $withState

    # ---- D1. the gates ------------------------------------------------------------------------------------------------------------------
    Add-Result 'D' 'gates: the recorded state WithIndexes passes as WithIndexes' (@(Get-StepGateFailures $withState 'WithIndexes').Count -eq 0)
    Add-Result 'D' 'gates: the state without the five indexes passes as WithoutIndexes' (@(Get-StepGateFailures $withoutState 'WithoutIndexes').Count -eq 0)
    Add-Result 'D' 'gates: comparison with the snapshot passes in both states (the WithoutIndexes facts are derived from the snapshot)' ((@(Get-StepGateFailures $withState 'WithIndexes' $snapshotState).Count -eq 0) -and (@(Get-StepGateFailures $withoutState 'WithoutIndexes' $snapshotState).Count -eq 0))
    Add-Result 'D' 'gates: the state with the indexes is refused as WithoutIndexes, and the reverse' ((@(Get-StepGateFailures $withState 'WithoutIndexes').Count -gt 0) -and (@(Get-StepGateFailures $withoutState 'WithIndexes').Count -gt 0))
    Add-Result 'D' 'gates: an unknown kind is refused' (@(Get-StepGateFailures $withState 'Other').Count -gt 0)
    $gateCases = @(
        @('wrong database (the development database)', 'WithIndexes', (Edit-Lines $withLines 'target|*' 'db=RequestManagement_Perf' 'db=RequestManagement'), 'database is'),
        @('wrong database (a longer name)', 'WithIndexes', (Edit-Lines $withLines 'target|*' 'db=RequestManagement_Perf' 'db=RequestManagement_Perf2'), 'database is'),
        @('marker missing', 'WithIndexes', (Edit-Lines $withLines 'target|*' 'marker=1' 'marker=0'), 'marker'),
        @('database offline', 'WithIndexes', (Edit-Lines $withLines 'target|*' 'state=ONLINE' 'state=OFFLINE'), 'state'),
        @('database read-only', 'WithIndexes', (Edit-Lines $withLines 'target|*' 'readonly=0' 'readonly=1'), 'read-only'),
        @('no target line', 'WithIndexes', (Drop-Lines $withLines 'target|*'), 'target line'),
        @('too few rows', 'WithIndexes', (Edit-Lines $withLines 'dataset|*' 'rows=100000' 'rows=99999'), 'rows'),
        @('wrong checksum', 'WithIndexes', (Edit-Lines $withLines 'dataset|*' '-1953119262' '-1953119261'), 'checksum'),
        @('no dataset line', 'WithIndexes', (Drop-Lines $withLines 'dataset|*'), 'dataset line'),
        @('distribution by status changed', 'WithIndexes', (Edit-Lines $withLines 'by_status|1|*' '19831' '19830'), 'status'),
        @('distribution by priority changed', 'WithIndexes', (Edit-Lines $withLines 'by_priority|3|*' '14829' '14828'), 'priority'),
        @('history rows appeared', 'WithIndexes', (Edit-Lines $withLines 'bounds|*' 'history_rows=0' 'history_rows=1'), 'bounds'),
        @('id bounds changed', 'WithIndexes', (Edit-Lines $withLines 'bounds|*' 'max_id=100000' 'max_id=100001'), 'bounds'),
        @('AddQueryIndexes missing from the history', 'WithIndexes', (Drop-Lines $withLines 'migration|20261020183100_AddQueryIndexes|*'), 'migration history'),
        @('an extra migration', 'WithIndexes', ($withLines + 'migration|20261026000000_Extra|10.0.13'), 'migration history'),
        @('one of the five indexes missing', 'WithIndexes', (Drop-Lines $withLines 'index|Requests|IX_Requests_CreatedAt_Id|*'), 'missing or has altered'),
        @('an index option altered (fill factor)', 'WithIndexes', (Edit-Lines $withLines 'index|Requests|IX_Requests_Priority_Status|*' 'fill=0' 'fill=90'), 'altered'),
        @('an index key order altered', 'WithIndexes', (Edit-Lines $withLines 'index|Requests|IX_Requests_Status_CreatedAt|*' 'CreatedAt DESC' 'CreatedAt ASC'), 'altered'),
        @('an include column dropped', 'WithIndexes', (Edit-Lines $withLines 'index|Requests|IX_Requests_Status_CreatedAt|*' 'include=Priority' 'include='), 'altered'),
        @('an unknown extra index on Requests', 'WithIndexes', ($withLines + (New-IndexLine 'Requests' 'IX_Requests_Extra' 'NONCLUSTERED' 0 0 'Title ASC' '')), 'unexpected'),
        @('one of the five indexes still present (state WithoutIndexes expected)', 'WithoutIndexes', ($withoutLines + (New-IndexLine 'Requests' 'IX_Requests_CreatedAt_Id' 'NONCLUSTERED' 0 0 'CreatedAt DESC, Id DESC' '')), 'unexpected'),
        @('primary key missing', 'WithIndexes', (Drop-Lines $withLines 'index|Requests|PK_Requests|*'), 'missing'),
        @('history index missing', 'WithIndexes', (Drop-Lines $withLines 'index|RequestStatusHistory|IX_RequestStatusHistory_RequestId_ChangedAt|*'), 'RequestStatusHistory'),
        @('a CHECK constraint missing', 'WithIndexes', (Drop-Lines $withLines 'constraint|Requests|CK_Requests_Status'), 'CHECK'),
        @('the foreign key missing', 'WithIndexes', (Drop-Lines $withLines 'fk|*'), 'foreign key'),
        @('the foreign key with another delete action', 'WithIndexes', (Edit-Lines $withLines 'fk|*' 'NO_ACTION' 'CASCADE'), 'foreign key'),
        @('another session on the database', 'WithIndexes', (Edit-Lines $withLines 'sessions|*' 'sessions|0' 'sessions|1'), 'session'),
        @('the session count unknown', 'WithIndexes', (Drop-Lines $withLines 'sessions|*'), 'unknown'),
        @('an error message among the lines', 'WithIndexes', ($withLines + 'Msg 208, Level 16, State 1, Invalid object name'), 'unexpected output'),
        @('an empty answer', 'WithIndexes', @(), 'no facts')
    )
    foreach ($case in $gateCases) {
        $failures = @(Get-StepGateFailures (ConvertTo-State $case[2]) $case[1])
        Add-Result 'D' "gate stops: $($case[0])" (($failures.Count -gt 0) -and (($failures -join ' ') -match [regex]::Escape($case[3]))) ($failures -join ' ; ')
    }
    $liveChangedHistoryIndex = Edit-Lines $withLines 'index|RequestStatusHistory|IX_RequestStatusHistory_RequestId_ChangedAt|*' 'fill=0' 'fill=80'
    Add-Result 'D' 'gate stops: a difference from the snapshot that no fixed rule covers (history index option)' ((@(Get-StepGateFailures (ConvertTo-State $liveChangedHistoryIndex) 'WithIndexes' $snapshotState) -join ' ') -match 'differs from the snapshot')
    $liveChangedCollation = Edit-Lines $withoutLines 'target|*' 'CP1_CI_AS' 'CP1_CS_AS'
    Add-Result 'D' 'gate stops: after the removal, any difference from the snapshot-without-indexes (collation)' ((@(Get-StepGateFailures (ConvertTo-State $liveChangedCollation) 'WithoutIndexes' $snapshotState) -join ' ') -match 'differs from the snapshot')
    Add-Result 'D' 'gate: pages and sessions are informational and are not compared with the snapshot' (@(Get-StepGateFailures (ConvertTo-State (Edit-Lines $withLines 'pages|Requests|PK_Requests|*' '2254' '2300')) 'WithIndexes' $snapshotState).Count -eq 0)

    # ---- D2. the snapshot file ------------------------------------------------------------------------------------------------------------
    $snapshotText = Format-StepSnapshot $withState '2026-10-26T12:00:00' 'localhost,1433'
    $snapshotPath = Join-Path $tempRoot 'roundtrip.txt'
    [IO.File]::WriteAllText($snapshotPath, $snapshotText)
    $readBack = Read-StepSnapshot $snapshotPath
    Add-Result 'D' 'snapshot: the recorded text reads back to the same facts and still passes every gate' ((($readBack.Facts -join "`n") -ceq ($withState.Facts -join "`n")) -and (@(Get-StepGateFailures $readBack 'WithIndexes').Count -eq 0) -and ($readBack.Sessions -eq 0))
    Add-Result 'D' 'snapshot: it carries comment headers, the compared facts hash, and no password or connection string' (($snapshotText -match '(?m)^# Facts sha256') -and ($snapshotText -notmatch '(?i)password|pwd=|User Id|Server=') -and -not $snapshotText.Contains($fake))
    Add-Result 'D' 'snapshot: its facts hash is stable and changes with any fact' ((Get-StepFactsSha256 $withState) -ceq (Get-StepFactsSha256 $readBack) -and (Get-StepFactsSha256 $withState) -cne (Get-StepFactsSha256 (ConvertTo-State (Edit-Lines $withLines 'dataset|*' 'rows=100000' 'rows=99999'))))

    # ---- D3. the approval -------------------------------------------------------------------------------------------------------------------
    $factsSha = Get-StepFactsSha256 $withState
    $code = Get-StepApprovalCode 'RemoveIndexes' $withState $factsSha
    Add-Result 'D' 'approval code: 12 upper-case hex characters, stable for the same state' (($code -cmatch '^[0-9A-F]{12}$') -and ($code -ceq (Get-StepApprovalCode 'RemoveIndexes' $withState $factsSha)))
    Add-Result 'D' 'approval code: independent of sessions and pages' ($code -ceq (Get-StepApprovalCode 'RemoveIndexes' (ConvertTo-State (Edit-Lines $withLines 'pages|Requests|PK_Requests|*' '2254' '9999')) $factsSha))
    Add-Result 'D' 'approval code: different for the other action, another snapshot, and any change of a fact' (
        ($code -cne (Get-StepApprovalCode 'RestoreIndexes' $withState $factsSha)) -and ($code -cne (Get-StepApprovalCode 'RemoveIndexes' $withState ('0' * 64))) -and
        ($code -cne (Get-StepApprovalCode 'RemoveIndexes' (ConvertTo-State (Edit-Lines $withLines 'dataset|*' 'rows=100000' 'rows=99999')) $factsSha)))
    $childLog = Join-Path $tempRoot 'schema-child.log'
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $childLog, 'Process')
    $script:SchemaChangeApproval = $null
    Add-Result 'D' 'Invoke-EfDatabaseUpdate without any grant stops with APPROVAL_REQUIRED' ((Get-StopCode { Invoke-EfDatabaseUpdate 'RemoveIndexes' $tempRoot }) -eq 'APPROVAL_REQUIRED')
    Add-Result 'D' 'a grant needs -ConfirmDatabase exactly RequestManagement_Perf' (
        ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' '' $code $code }) -eq 'CONFIRM_MISSING') -and ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'RequestManagement' $code $code }) -eq 'CONFIRM_MISSING') -and
        ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'requestmanagement_perf' $code $code }) -eq 'CONFIRM_MISSING'))
    Add-Result 'D' 'a grant needs a code: none is APPROVAL_REQUIRED, a wrong one or one of another state is APPROVAL_CODE_MISMATCH' (
        ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'RequestManagement_Perf' '' $code }) -eq 'APPROVAL_REQUIRED') -and ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'RequestManagement_Perf' 'AAAAAAAAAAAA' $code }) -eq 'APPROVAL_CODE_MISMATCH') -and
        ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'RequestManagement_Perf' (Get-StepApprovalCode 'RemoveIndexes' (ConvertTo-State (Edit-Lines $withLines 'dataset|*' 'rows=100000' 'rows=99999')) $factsSha) $code }) -eq 'APPROVAL_CODE_MISMATCH') -and
        ((Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'RequestManagement_Perf' (Get-StepApprovalCode 'RestoreIndexes' $withState $factsSha) $code }) -eq 'APPROVAL_CODE_MISMATCH'))
    Add-Result 'D' 'every failed grant leaves no approval behind' ($null -eq $script:SchemaChangeApproval)
    [void](Get-StopCode { Grant-SchemaChangeApproval 'RemoveIndexes' 'RequestManagement_Perf' $code $code })
    Add-Result 'D' 'a correct grant records an unused approval for that action only' (($null -ne $script:SchemaChangeApproval) -and ($script:SchemaChangeApproval.Action -ceq 'RemoveIndexes') -and -not $script:SchemaChangeApproval.Used)
    Add-Result 'D' 'an approval for RemoveIndexes does not open RestoreIndexes' ((Get-StopCode { Invoke-EfDatabaseUpdate 'RestoreIndexes' $tempRoot }) -eq 'APPROVAL_ACTION_MISMATCH')
    Add-Result 'D' 'with the approval but without the guard, the command still stops before it starts (the next gate holds)' ((Get-StopCode { Invoke-EfDatabaseUpdate 'RemoveIndexes' $tempRoot }) -eq 'GUARD_NOT_APPROVED')
    Add-Result 'D' 'the approval is single-use: it is used up even though the command did not start' (($script:SchemaChangeApproval.Used) -and ((Get-StopCode { Invoke-EfDatabaseUpdate 'RemoveIndexes' $tempRoot }) -eq 'APPROVAL_REQUIRED'))
    Add-Result 'D' 'none of this launched a process (T501_CHILD_LOG not written)' (-not (Test-Path -LiteralPath $childLog))
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $null, 'Process')
    $script:SchemaChangeApproval = $null
    Add-Result 'D' 'the update arguments: RemoveIndexes migrates to InitialCreate, RestoreIndexes to the latest; both use --no-build and the Infrastructure project' (
        ((Get-EfUpdateArguments 'RemoveIndexes') -join ' ') -ceq 'ef database update InitialCreate --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure --no-build --no-color' -and
        ((Get-EfUpdateArguments 'RestoreIndexes') -join ' ') -ceq 'ef database update --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure --no-build --no-color')
    Add-Result 'D' 'the update arguments cannot be built for Snapshot, Check or anything else' (((Get-StopCode { Get-EfUpdateArguments 'Snapshot' }) -eq 'ACTION_NOT_ALLOWED') -and ((Get-StopCode { Get-EfUpdateArguments 'Check' }) -eq 'ACTION_NOT_ALLOWED') -and ((Get-StopCode { Get-EfUpdateArguments '' }) -eq 'ACTION_NOT_ALLOWED'))

    # ---- D4. the state query is read-only and cannot run without the guard ---------------------------------------------------------------
    Add-Result 'D' 'the SchemaState query passes the read-only grammar and is SELECT-only' ((Get-StopCode { Assert-ReadOnlySql (Get-ApprovedSql 'SchemaState' '' $false) }) -eq 'NONE')
    # sqlcmd with -X ignores SQLCMDPASSWORD (found against the live container); the password must still not be an argument.
    $commonSource = Get-Content -LiteralPath $commonPath -Raw
    $sqlcmdArgsLine = [regex]::Match($commonSource, '(?m)^\s*\$arguments = @\(''-S''.*$').Value
    Add-Result 'D' 'sqlcmd arguments: no -X (it would ignore SQLCMDPASSWORD) and no -P (the password is never an argument)' (($sqlcmdArgsLine -ne '') -and ($sqlcmdArgsLine -notmatch "'-X'") -and ($sqlcmdArgsLine -notmatch "'-P'") -and ($commonSource -notmatch "'-P'"))
    # Found against the live database (Msg 451): catalog *_desc columns have a fixed collation that conflicts with sysname columns.
    foreach ($queryName in @('SchemaState', 'IndexListing')) {
        $queryText = Get-ApprovedSql $queryName '' $false
        $descUses = @([regex]::Matches($queryText, '\w+_desc\b'))
        $unprotected = @([regex]::Matches($queryText, '\w+_desc\b(?! AS nvarchar\(60\)\) COLLATE DATABASE_DEFAULT)') | ForEach-Object { $_.Value })
        Add-Result 'D' "$queryName query: every catalog *_desc column is cast and given COLLATE DATABASE_DEFAULT (no collation conflict with sysname columns)" (($descUses.Count -gt 0) -and ($unprotected.Count -eq 0) -and ((Get-StopCode { Assert-ReadOnlySql $queryText }) -eq 'NONE')) ($unprotected -join ' ; ')
    }
    $savedSqlcmdIni = [Environment]::GetEnvironmentVariable('SQLCMDINI', 'Process')
    $savedSqlcmdUser = [Environment]::GetEnvironmentVariable('SQLCMDUSER', 'Process')
    [Environment]::SetEnvironmentVariable('SQLCMDINI', 'C:\evil\startup.sql', 'Process')
    [Environment]::SetEnvironmentVariable('SQLCMDUSER', 'someone', 'Process')
    $sqlcmdEnv = Get-PerfSqlcmdEnvironment 'unused-test-password'
    [Environment]::SetEnvironmentVariable('SQLCMDINI', $savedSqlcmdIni, 'Process')
    [Environment]::SetEnvironmentVariable('SQLCMDUSER', $savedSqlcmdUser, 'Process')
    Add-Result 'D' 'sqlcmd environment: SQLCMDPASSWORD is set, and any other SQLCMD* variable of the parent (startup script, user) is removed for the child' (
        ($sqlcmdEnv['SQLCMDPASSWORD'] -ceq 'unused-test-password') -and $sqlcmdEnv.ContainsKey('SQLCMDINI') -and ($null -eq $sqlcmdEnv['SQLCMDINI']) -and $sqlcmdEnv.ContainsKey('SQLCMDUSER') -and ($null -eq $sqlcmdEnv['SQLCMDUSER']))
    $script:PerfGuardApproval = $null
    Add-Result 'D' 'the SchemaState query cannot be sent without the guard approval' ((Get-StopCode { Invoke-PerfSqlcmd -Builder $goodBuilder -Kind SchemaState -WorkDir $tempRoot }) -eq 'GUARD_NOT_APPROVED')

    # ---- D5. the SQL of the removal and the restoration (generated offline, no connection) -----------------------------------------------------
    $savedEfEnv = [Environment]::GetEnvironmentVariable($envName, 'Process')
    [Environment]::SetEnvironmentVariable($envName, $null, 'Process')
    Push-Location (Join-Path (Split-Path (Split-Path $perfDir -Parent) -Parent) 'backend')
    try {
        $ef = @('--project', 'src/RequestManagement.Infrastructure', '--startup-project', 'src/RequestManagement.Infrastructure', '--no-build', '--no-color')
        $down = (dotnet ef migrations script AddQueryIndexes InitialCreate @ef 2>&1 | Out-String)
        $up = (dotnet ef migrations script InitialCreate AddQueryIndexes @ef 2>&1 | Out-String)
    }
    finally { Pop-Location; [Environment]::SetEnvironmentVariable($envName, $savedEfEnv, 'Process') }
    Add-Result 'D' 'EF removal SQL (AddQueryIndexes to InitialCreate, generated offline) equals the expected text: 5 DROP INDEX and the history DELETE in one transaction' (Test-EfScriptMatches 'Remove' $down)
    Add-Result 'D' 'EF restoration SQL (InitialCreate to AddQueryIndexes, generated offline) equals the expected text: 5 CREATE INDEX with DESC and INCLUDE, and the history INSERT' (Test-EfScriptMatches 'Restore' $up)
    $badScripts = [ordered]@{
        'an extra DROP TABLE'        = ($down + "`nDROP TABLE [Requests];")
        'one DROP INDEX missing'     = ($down -replace 'DROP INDEX \[IX_Requests_Priority_Status\] ON \[Requests\];', '')
        'a TRUNCATE'                 = ($down + "`nTRUNCATE TABLE [Requests];")
        'the removal used as the restoration' = $down
        'a CREATE without INCLUDE'   = ($up -replace ' INCLUDE \(\[Priority\]\)', '')
        'an altered key order'       = ($up -replace '\[CreatedAt\] DESC, \[Id\] DESC', '[CreatedAt], [Id]')
        'a different migration id'   = ($down -replace '20261020183100_AddQueryIndexes', '20261020183000_InitialCreate')
        'an empty script'            = ''
    }
    foreach ($name in $badScripts.Keys) {
        $direction = if ($name -eq 'the removal used as the restoration') { 'Restore' } elseif ($name -match 'CREATE|key order') { 'Restore' } else { 'Remove' }
        Add-Result 'D' "EF SQL check refuses: $name" (-not (Test-EfScriptMatches $direction $badScripts[$name]))
    }

    # ---- D5b. the EF script, parsed and compared with the RECORDED indexes (not with a hand-written expectation) ------------------------------------------
    function ConvertFrom-EfCreateIndexes([string]$Script) {
        @([regex]::Matches($Script, '(?m)^CREATE INDEX \[(?<n>\w+)\] ON \[(?<t>\w+)\] \((?<k>[^)]*)\)(?: INCLUDE \((?<i>[^)]*)\))?;\s*$') | ForEach-Object {
            $keys = (($_.Groups['k'].Value -split ',\s*') | ForEach-Object { $c = $_.Trim(); if ($c -match '^\[(\w+)\] DESC$') { "$($matches[1]) DESC" } elseif ($c -match '^\[(\w+)\]$') { "$($matches[1]) ASC" } else { "?$c" } }) -join ', '
            $include = if ($_.Groups['i'].Success) { (($_.Groups['i'].Value -split ',\s*') | ForEach-Object { $_.Trim('[', ']') }) -join ', ' } else { '' }
            Format-StepIndexLine $_.Groups['t'].Value $_.Groups['n'].Value 'NONCLUSTERED' 0 0 $keys $include
        })
    }
    $recordedSources = [ordered]@{ 'the hand-written state' = $withState }
    $realSnapshotPath = Join-Path $perfDir 'snapshots\RequestManagement_Perf.pre-step2.txt'
    if (Test-Path -LiteralPath $realSnapshotPath) { $recordedSources['the recorded live snapshot'] = (Read-StepSnapshot $realSnapshotPath) }
    foreach ($label in $recordedSources.Keys) {
        $recorded = $recordedSources[$label]
        $recordedQueryIndexes = @($recorded.Facts | Where-Object { $_ -like 'index|Requests|IX_Requests_*' })
        $recordedNames = @($recordedQueryIndexes | ForEach-Object { ($_ -split '\|')[2] })
        $fromEf = @(ConvertFrom-EfCreateIndexes $up)
        Add-Result 'D' "restoration SQL vs $label : the five indexes come back with the same names, key columns and order, DESC, INCLUDE, and default options (line for line)" (
            ($recordedQueryIndexes.Count -eq 5) -and ($fromEf.Count -eq 5) -and ((Sort-StepOrdinal $fromEf) -join "`n") -ceq ((Sort-StepOrdinal $recordedQueryIndexes) -join "`n"))
        $dropped = @([regex]::Matches($down, '(?m)^DROP INDEX \[(\w+)\] ON \[Requests\];') | ForEach-Object { $_.Groups[1].Value })
        Add-Result 'D' "removal SQL vs $label : drops exactly the five recorded query indexes of Requests and nothing else" (
            ($dropped.Count -eq 5) -and ((Sort-StepOrdinal $dropped) -join ',') -ceq ((Sort-StepOrdinal $recordedNames) -join ',') -and ([regex]::Matches($down, '(?im)^\s*(DROP|ALTER|DELETE|UPDATE|INSERT|TRUNCATE|CREATE)\b').Count -eq 6))
        $recordedVersion = (@($recorded.Facts | Where-Object { $_ -like 'migration|20261020183100_AddQueryIndexes|*' })[0] -split '\|')[2]
        $insertedVersion = [regex]::Match($up, "VALUES \(N'20261020183100_AddQueryIndexes', N'([^']+)'\);").Groups[1].Value
        Add-Result 'D' "restoration SQL vs $label : the history row is inserted for AddQueryIndexes only, with the recorded ProductVersion ($recordedVersion)" (
            ($insertedVersion -ceq $recordedVersion) -and ([regex]::Matches($up, '(?m)^INSERT INTO \[__EFMigrationsHistory\]').Count -eq 1) -and ([regex]::Matches($down, '(?m)^DELETE FROM \[__EFMigrationsHistory\]').Count -eq 1) -and ($down -match "WHERE \[MigrationId\] = N'20261020183100_AddQueryIndexes';"))
    }
    Add-Result 'D' 'restoration SQL: no WITH option (fill factor, pad, compression, online, ...) and nothing but CREATE INDEX plus the history INSERT, in one transaction' (
        ($up -notmatch '(?i)\bWITH\b|FILLFACTOR|PAD_INDEX|DATA_COMPRESSION|ONLINE|DROP_EXISTING|IGNORE_DUP') -and ([regex]::Matches($up, '(?im)^\s*(DROP|ALTER|DELETE|UPDATE|TRUNCATE)\b').Count -eq 0) -and
        ([regex]::Matches($up, '(?im)^BEGIN TRANSACTION;').Count -eq 1) -and ([regex]::Matches($up, '(?im)^COMMIT;').Count -eq 1))
    Add-Result 'D' 'removal SQL: the generated script is one transaction (BEGIN TRANSACTION ... COMMIT); that `database update` runs the same commands in one transaction is EF behaviour and is not exercised here' (([regex]::Matches($down, '(?im)^BEGIN TRANSACTION;').Count -eq 1) -and ([regex]::Matches($down, '(?im)^COMMIT;').Count -eq 1))

    # ---- D5c. partial states are told apart reliably, and the post-check says what is safe ------------------------------------------------------------
    $oneIx = 'IX_Requests_CreatedAt_Id'
    $allIxLike = 'index|Requests|IX_Requests_*'
    $historyLike = 'migration|20261020183100_AddQueryIndexes|*'
    $ixLines = @($withLines | Where-Object { $_ -like $allIxLike })
    $classCases = @(
        @('all five and the history row', $withLines, 'WITH_INDEXES'),
        @('none of the five, no history row', $withoutLines, 'WITHOUT_INDEXES'),
        @('four of five, history row present', (Drop-Lines $withLines "index|Requests|$oneIx|*"), 'PARTIAL_SOME_INDEXES'),
        @('four of five, history row gone', (Drop-Lines (Drop-Lines $withLines "index|Requests|$oneIx|*") $historyLike), 'PARTIAL_SOME_INDEXES_HISTORY_MISSING'),
        @('three of five, history row gone', (Drop-Lines (Drop-Lines (Drop-Lines $withLines "index|Requests|$oneIx|*") 'index|Requests|IX_Requests_Priority_Status|*') $historyLike), 'PARTIAL_SOME_INDEXES_HISTORY_MISSING'),
        @('one of five, history row present', (@($withLines | Where-Object { $_ -notlike $allIxLike }) + $ixLines[0]), 'PARTIAL_SOME_INDEXES'),
        @('none of the five, history row still there', (Drop-Lines $withLines $allIxLike), 'INDEXES_GONE_HISTORY_PRESENT'),
        @('all five, history row missing', (Drop-Lines $withLines $historyLike), 'INDEXES_PRESENT_HISTORY_MISSING'),
        @('an index with another fill factor', (Edit-Lines $withLines 'index|Requests|IX_Requests_Priority_Status|*' 'fill=0' 'fill=90'), 'INDEX_ALTERED'),
        @('an index with another key order', (Edit-Lines $withLines "index|Requests|$oneIx|*" 'CreatedAt DESC, Id DESC' 'CreatedAt ASC, Id DESC'), 'INDEX_ALTERED'),
        @('the history row with another ProductVersion', (Edit-Lines $withLines $historyLike '10.0.13' '10.0.14'), 'INDEX_ALTERED'),
        @('wrong checksum', (Edit-Lines $withLines 'dataset|*' '-1953119262' '-1953119261'), 'DATA_OR_TARGET_DIFFERS'),
        @('fewer rows', (Edit-Lines $withLines 'dataset|*' 'rows=100000' 'rows=99999'), 'DATA_OR_TARGET_DIFFERS'),
        @('marker missing', (Edit-Lines $withLines 'target|*' 'marker=1' 'marker=0'), 'DATA_OR_TARGET_DIFFERS'),
        @('another database', (Edit-Lines $withLines 'target|*' 'db=RequestManagement_Perf' 'db=RequestManagement'), 'DATA_OR_TARGET_DIFFERS'),
        @('a history row in RequestStatusHistory', (Edit-Lines $withLines 'bounds|*' 'history_rows=0' 'history_rows=3'), 'DATA_OR_TARGET_DIFFERS'),
        @('an extra index on Requests', ($withLines + (New-IndexLine 'Requests' 'IX_Requests_Extra' 'NONCLUSTERED' 0 0 'Title ASC' '')), 'DATA_OR_TARGET_DIFFERS'),
        @('the primary key of Requests missing', (Drop-Lines $withLines 'index|Requests|PK_Requests|*'), 'DATA_OR_TARGET_DIFFERS'),
        @('the foreign key missing', (Drop-Lines $withLines 'fk|*'), 'DATA_OR_TARGET_DIFFERS'),
        @('partial indexes AND a wrong checksum', (Edit-Lines (Drop-Lines $withLines "index|Requests|$oneIx|*") 'dataset|*' '-1953119262' '-1953119261'), 'DATA_OR_TARGET_DIFFERS'),
        @('an error message among the lines', ($withLines + 'Msg 208, Level 16, State 1, Invalid object name'), 'DATA_OR_TARGET_DIFFERS'),
        @('an empty answer', @(), 'DATA_OR_TARGET_DIFFERS'))
    foreach ($case in $classCases) {
        $cls = Get-StepStateClassification (ConvertTo-State $case[1]) $snapshotState
        Add-Result 'D' "classification: $($case[0]) -> $($case[2])" ($cls.Class -ceq $case[2]) "got $($cls.Class)"
    }
    $partial = Get-StepStateClassification (ConvertTo-State (Drop-Lines $withLines "index|Requests|$oneIx|*")) $snapshotState
    Add-Result 'D' 'classification names the missing index and counts the ones as recorded' ((@($partial.Missing) -join ',') -ceq $oneIx -and (@($partial.Present).Count -eq 4) -and ($partial.History -ceq 'present'))
    $sessionClass = Get-StepStateClassification (ConvertTo-State (Edit-Lines $withLines 'sessions|*' 'sessions|0' 'sessions|2')) $snapshotState
    Add-Result 'D' 'classification does not hide another session: the text says a command may still be running' (($sessionClass.Class -ceq 'WITH_INDEXES') -and ((Format-StepClassification $sessionClass) -match '2 other session\(s\).*still be running'))
    Add-Result 'D' 'every class has advice; the repair classes say not to use the EF update command, and unknown classes are flagged' (
        (@('WITH_INDEXES', 'WITHOUT_INDEXES', 'PARTIAL_SOME_INDEXES', 'PARTIAL_SOME_INDEXES_HISTORY_MISSING', 'INDEXES_GONE_HISTORY_PRESENT', 'INDEXES_PRESENT_HISTORY_MISSING', 'INDEX_ALTERED', 'DATA_OR_TARGET_DIFFERS' | Where-Object { (Get-StepRecoveryAdvice $_) -match '^\w' -and (Get-StepRecoveryAdvice $_) -cne 'Unknown class.' }).Count -eq 8) -and
        ((Get-StepRecoveryAdvice 'PARTIAL_SOME_INDEXES') -match 'Do not run the EF update') -and ((Get-StepRecoveryAdvice 'INDEXES_GONE_HISTORY_PRESENT') -match 'treat the migration as applied') -and ((Get-StepRecoveryAdvice 'nonsense') -ceq 'Unknown class.'))
    # A history row is never added by hand because the indexes look right: the two classes that mean "history missing" say STOP.
    $allAdvice = @('WITH_INDEXES', 'WITHOUT_INDEXES', 'PARTIAL_SOME_INDEXES', 'PARTIAL_SOME_INDEXES_HISTORY_MISSING', 'INDEXES_GONE_HISTORY_PRESENT', 'INDEXES_PRESENT_HISTORY_MISSING', 'INDEX_ALTERED', 'DATA_OR_TARGET_DIFFERS' | ForEach-Object { Get-StepRecoveryAdvice $_ })
    foreach ($class in @('INDEXES_PRESENT_HISTORY_MISSING', 'PARTIAL_SOME_INDEXES_HISTORY_MISSING')) {
        $advice = Get-StepRecoveryAdvice $class
        Add-Result 'D' "advice $class : STOP, manual investigation, do not add the history row, do not use the EF update command" (
            $advice.StartsWith('STOP.') -and $advice.Contains('Manual investigation') -and $advice.Contains('Do not add') -and ($advice -match 'EF update command'))
    }
    Add-Result 'D' 'INDEXES_PRESENT_HISTORY_MISSING advice says why: the scripts compare indexes, constraint and foreign key names and data, not the rest of the schema' (
        ((Get-StepRecoveryAdvice 'INDEXES_PRESENT_HISTORY_MISSING') -match 'do not prove that the rest of the schema') -and ((Get-StepRecoveryAdvice 'INDEXES_PRESENT_HISTORY_MISSING') -match 'only index definitions, constraint and foreign key names, and the data'))
    Add-Result 'D' 'no advice, anywhere, tells anybody to insert a history row' (@($allAdvice | Where-Object { $_ -match '(?i)insert (the|a|one)\b.*history' -and $_ -notmatch '(?i)do not' }).Count -eq 0)
    $docText = Get-Content -LiteralPath (Join-Path $perfDir 'SCHEMA_STEP.md') -Raw
    Add-Result 'D' 'SCHEMA_STEP.md contains no statement that adds an __EFMigrationsHistory row, and no instruction to insert one' (
        ($docText -notmatch '(?i)INSERT\s+INTO\s+\[?__EFMigrationsHistory') -and ($docText -notmatch '(?i)insert the (one )?history row') -and $docText.Contains('There is no statement that adds the `AddQueryIndexes` row, on purpose.') -and $docText.Contains('### History row missing'))
    Add-Result 'D' 'SCHEMA_STEP.md says what the state query does not capture (columns, CHECK expressions, foreign key columns, triggers, statistics, filegroups) and demands a complete-schema comparison' (
        $docText.Contains('columns (types, nullability, defaults, collation), CHECK expressions, foreign key columns, triggers, statistics or filegroups') -and $docText.Contains('Compare the **complete** schema'))
    $manualBlock = [regex]::Match($docText, '(?s)```sql\s*SET XACT_ABORT ON;.*?```').Value
    $manualCode = @($manualBlock -split "`n" | Where-Object { $_ -notmatch '^\s*--' -and $_.Trim() -ne '' })
    Add-Result 'D' 'SCHEMA_STEP.md: the only active manual statements are the guard, the transaction and CREATE INDEX of the exact EF text; the DELETE is a comment tied to INDEXES_GONE_HISTORY_PRESENT' (
        ($manualBlock -ne '') -and (@($manualCode | Where-Object { $_ -match '^\s*(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|ALTER|DROP)\b' }).Count -eq 0) -and (@($manualCode | Where-Object { $_ -match '^CREATE INDEX ' }).Count -eq 5) -and
        $manualBlock.Contains('-- only for class INDEXES_GONE_HISTORY_PRESENT') -and $manualBlock.Contains("-- DELETE FROM [__EFMigrationsHistory] WHERE [MigrationId] = N'20261020183100_AddQueryIndexes';"))
    $classifierText = ((Get-Content -LiteralPath (Join-Path $perfDir 'perf-schema-step.ps1') -Raw) -split 'function Get-StepStateClassification')[1]
    Add-Result 'D' 'the classifier and its advice are text only: no process, no SQL, no file or environment access' ($classifierText -notmatch 'Invoke-|Start-Process|Resolve-PerfTool|Set-Content|Out-File|WriteAllText|Remove-Item|\$env:|Get-Content')

    $removeOk = Get-StepPostCheckStop $withoutState 'WithoutIndexes' $snapshotState
    $restoreOk = Get-StepPostCheckStop $withState 'WithIndexes' $snapshotState
    Add-Result 'D' 'post-check: the expected state after the removal and after the restoration gives no stop' (($null -eq $removeOk) -and ($null -eq $restoreOk))
    $postCases = @(
        @('removal did nothing (indexes still there)', $withState, 'WithoutIndexes', 'NOT in the intended state', 'WITH_INDEXES'),
        @('removal left some indexes', (ConvertTo-State (Drop-Lines $withLines "index|Requests|$oneIx|*")), 'WithoutIndexes', 'NOT in the intended state', 'PARTIAL_SOME_INDEXES'),
        @('removal dropped the indexes but not the history row', (ConvertTo-State (Drop-Lines $withLines $allIxLike)), 'WithoutIndexes', 'NOT in the intended state', 'INDEXES_GONE_HISTORY_PRESENT'),
        @('removal done, another session connected', (ConvertTo-State (Edit-Lines $withoutLines 'sessions|*' 'sessions|0' 'sessions|1')), 'WithoutIndexes', 'schema change itself IS complete', 'WITHOUT_INDEXES'),
        @('removal done, but the checksum differs', (ConvertTo-State (Edit-Lines $withoutLines 'dataset|*' '-1953119262' '-1953119261')), 'WithoutIndexes', 'NOT in the intended state', 'DATA_OR_TARGET_DIFFERS'),
        @('restoration did nothing (indexes still missing)', $withoutState, 'WithIndexes', 'NOT in the intended state', 'WITHOUT_INDEXES'),
        @('restoration created the indexes but not the history row', (ConvertTo-State (Drop-Lines $withLines $historyLike)), 'WithIndexes', 'NOT in the intended state', 'INDEXES_PRESENT_HISTORY_MISSING'),
        @('restoration created some indexes', (ConvertTo-State (Drop-Lines (Drop-Lines $withLines "index|Requests|$oneIx|*") $historyLike)), 'WithIndexes', 'NOT in the intended state', 'PARTIAL_SOME_INDEXES_HISTORY_MISSING'),
        @('restoration done, another session connected', (ConvertTo-State (Edit-Lines $withLines 'sessions|*' 'sessions|0' 'sessions|1')), 'WithIndexes', 'schema change itself IS complete', 'WITH_INDEXES'),
        @('restoration with another ProductVersion in the history', (ConvertTo-State (Edit-Lines $withLines $historyLike '10.0.13' '10.0.15')), 'WithIndexes', 'NOT in the intended state', 'INDEX_ALTERED'))
    foreach ($case in $postCases) {
        $stop = Get-StepPostCheckStop $case[1] $case[2] $snapshotState
        Add-Result 'D' "post-check fails and says what is safe: $($case[0])" (($null -ne $stop) -and $stop.Contains($case[3]) -and $stop.Contains("Classification: $($case[4])") -and $stop.Contains('Nothing is repaired automatically') -and ($stop -notmatch 'the restore procedure is')) $stop
    }

    # ---- D5d. the original snapshot is pinned --------------------------------------------------------------------------------------------------------
    Add-Result 'D' 'pin: the facts hash of the hand-written recorded state equals the pinned original (so the tests use the same facts as the real snapshot)' ((Get-StepFactsSha256 $withState) -ceq $script:StepOriginalSnapshotFactsSha256) (Get-StepFactsSha256 $withState)
    if (Test-Path -LiteralPath $realSnapshotPath) {
        $realState = Read-StepSnapshot $realSnapshotPath
        $realText = [IO.File]::ReadAllText($realSnapshotPath)
        Add-Result 'D' 'pin: the real snapshot file recomputes to the pinned hash, carries the same hash in its header, and passes every gate as WithIndexes' (
            ((Get-StepFactsSha256 $realState) -ceq $script:StepOriginalSnapshotFactsSha256) -and $realText.Contains("# Facts sha256 (the compared lines only): $($script:StepOriginalSnapshotFactsSha256)") -and (@(Get-StepGateFailures $realState 'WithIndexes').Count -eq 0))
    }
    Add-Result 'D' 'pin: a valid state that differs in one fact has another hash' ((Get-StepFactsSha256 (ConvertTo-State (Edit-Lines $withLines 'target|*' 'CP1_CI_AS' 'CP1_CS_AS'))) -cne $script:StepOriginalSnapshotFactsSha256)

    # ---- D6. set-index-state.ps1 as a child process: every stop before anything is started -------------------------------------------------------
    $snapRoot = Join-Path $tempRoot 'snap-root'
    New-Item -ItemType Directory -Path $snapRoot | Out-Null
    $snapFile = Join-Path $snapRoot 'RequestManagement_Perf.pre-step2.txt'
    [IO.File]::WriteAllText($snapFile, $snapshotText)
    $emptySnapRoot = Join-Path $tempRoot 'snap-empty'
    $badSnapRoot = Join-Path $tempRoot 'snap-bad'
    New-Item -ItemType Directory -Path $badSnapRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $badSnapRoot 'RequestManagement_Perf.pre-step2.txt'), (($snapshotText -split "`n") | ForEach-Object { $_.Replace('checksum=-1953119262', 'checksum=-1953119261') }) -join "`n")
    $garbageRoot = Join-Path $tempRoot 'snap-garbage'
    New-Item -ItemType Directory -Path $garbageRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $garbageRoot 'RequestManagement_Perf.pre-step2.txt'), "this is not a snapshot`n")
    $goodCode = 'ABCDEF012345'
    $stopCases2 = @(
        @('no action', @(), $goodCs, 'ACTION_MISSING'),
        @('-Execute with Check', @('-Action', 'Check', '-Execute'), $goodCs, 'EXECUTE_NOT_ALLOWED'),
        @('-Execute with Snapshot', @('-Action', 'Snapshot', '-Execute'), $goodCs, 'EXECUTE_NOT_ALLOWED'),
        @('-ConfirmDatabase without -Execute', @('-Action', 'RemoveIndexes', '-ConfirmDatabase', 'RequestManagement_Perf'), $goodCs, 'APPROVAL_WITHOUT_EXECUTE'),
        @('-ApprovalCode without -Execute', @('-Action', 'RemoveIndexes', '-ApprovalCode', $goodCode), $goodCs, 'APPROVAL_WITHOUT_EXECUTE'),
        @('-Overwrite with Check', @('-Action', 'Check', '-Overwrite'), $goodCs, 'OVERWRITE_NOT_ALLOWED'),
        @('-Execute without -ConfirmDatabase', @('-Action', 'RemoveIndexes', '-Execute', '-ApprovalCode', $goodCode, '-SnapshotRoot', $snapRoot), $goodCs, 'CONFIRM_MISSING'),
        @('-Execute with the development database as confirmation', @('-Action', 'RemoveIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement', '-ApprovalCode', $goodCode, '-SnapshotRoot', $snapRoot), $goodCs, 'CONFIRM_MISSING'),
        @('-Execute without an approval code', @('-Action', 'RemoveIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-SnapshotRoot', $snapRoot), $goodCs, 'APPROVAL_REQUIRED'),
        @('-Execute with a malformed approval code', @('-Action', 'RestoreIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-ApprovalCode', 'xyz', '-SnapshotRoot', $snapRoot), $goodCs, 'APPROVAL_CODE_MISMATCH'),
        @('environment variable not set', @('-Action', 'Check'), $null, 'ENV_MISSING'),
        @('dev database', @('-Action', 'Check'), (Cs 'localhost,1433' 'RequestManagement'), 'TARGET_MISMATCH'),
        @('remote server', @('-Action', 'Snapshot'), (Cs 'sql.example.com,1433' 'RequestManagement_Perf'), 'TARGET_MISMATCH'),
        @('wrong port', @('-Action', 'RemoveIndexes'), (Cs 'localhost,1434' 'RequestManagement_Perf'), 'TARGET_MISMATCH'),
        @('Perf name in the wrong case', @('-Action', 'RestoreIndexes'), (Cs 'localhost,1433' 'requestmanagement_perf'), 'TARGET_MISMATCH'),
        @('snapshot root = the official results folder', @('-Action', 'Snapshot', '-SnapshotRoot', (Join-Path $perfDir 'results')), $goodCs, 'SNAPSHOT_ROOT_IS_RESULTS'),
        @('snapshot root inside the official results folder', @('-Action', 'Snapshot', '-SnapshotRoot', (Join-Path $perfDir 'results\before')), $goodCs, 'RESULTS_ROOT_INSIDE_OFFICIAL'),
        @('RemoveIndexes without a snapshot', @('-Action', 'RemoveIndexes', '-SnapshotRoot', $emptySnapRoot), $goodCs, 'SNAPSHOT_MISSING'),
        @('RestoreIndexes -Execute without a snapshot', @('-Action', 'RestoreIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-ApprovalCode', $goodCode, '-SnapshotRoot', $emptySnapRoot), $goodCs, 'SNAPSHOT_MISSING'),
        @('a snapshot with a wrong checksum', @('-Action', 'Check', '-SnapshotRoot', $badSnapRoot), $goodCs, 'SNAPSHOT_INVALID'),
        @('a snapshot that is not a snapshot', @('-Action', 'RemoveIndexes', '-SnapshotRoot', $garbageRoot), $goodCs, 'SNAPSHOT_INVALID'),
        @('an existing snapshot without -Overwrite', @('-Action', 'Snapshot', '-SnapshotRoot', $snapRoot), $goodCs, 'RESULTS_EXIST')
    )
    $snapBefore = Get-TreeSnapshot $snapRoot
    foreach ($case in $stopCases2) {
        $r = Invoke-Script $setIndexState $case[1] $case[2]
        $ok = ($r.Exit -eq 1) -and $r.Output.Contains("[$($case[3])]") -and -not $r.Output.Contains($fake) -and ($r.Started.Count -eq 0) -and -not $r.Output.Contains('DRY RUN OK') -and -not $r.Output.Contains('CHANGE OK')
        Add-Result 'D' "set-index-state stops with $($case[3]): $($case[0])" $ok "exit $($r.Exit); started $($r.Started.Count)"
    }
    Add-Result 'D' 'an existing snapshot is never replaced by those stops' ((Get-TreeSnapshot $snapRoot) -ceq $snapBefore)
    foreach ($bad in @(@('invalid action', @('-Action', 'DropEverything')), @('invalid snapshot name', @('-Action', 'Check', '-SnapshotName', 'a b')), @('unknown parameter', @('-Action', 'Check', '-Frobnicate')))) {
        $r = Invoke-Script $setIndexState $bad[1] $goodCs
        Add-Result 'D' "set-index-state rejects $($bad[0])" (($r.Exit -ne 0) -and ($r.Started.Count -eq 0) -and -not $r.Output.Contains('DRY RUN OK'))
    }

    # ---- D7. dry run: plans every gate, starts nothing, writes nothing --------------------------------------------------------------------------
    foreach ($case in @(
            @('Snapshot', @('-Action', 'Snapshot', '-SnapshotRoot', $emptySnapRoot, '-DryRun')),
            @('Check', @('-Action', 'Check', '-SnapshotRoot', $snapRoot, '-DryRun')),
            @('RemoveIndexes, default (stops before the change)', @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot, '-DryRun')),
            @('RemoveIndexes -Execute', @('-Action', 'RemoveIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-ApprovalCode', $goodCode, '-SnapshotRoot', $snapRoot, '-DryRun')),
            @('RestoreIndexes -Execute', @('-Action', 'RestoreIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-ApprovalCode', $goodCode, '-SnapshotRoot', $snapRoot, '-DryRun')))) {
        $before = Get-TreeSnapshot $snapRoot
        $r = Invoke-Script $setIndexState $case[1] $goodCs
        $gateLines = @($r.Output -split "`r?`n" | Where-Object { $_ -match '^PLAN GATE:' })
        Add-Result 'D' "dry run ($($case[0])): exits 0, plans all five gates, started nothing, wrote nothing, no secrets" (
            ($r.Exit -eq 0) -and $r.Output.Contains('DRY RUN OK - nothing was executed.') -and ($gateLines.Count -eq 5) -and ($r.Started.Count -eq 0) -and ((Get-TreeSnapshot $snapRoot) -ceq $before) -and
            -not $r.Output.Contains($fake) -and -not $r.Output.Contains('Password=')) "gates $($gateLines.Count); started $($r.Started.Count)"
    }
    Add-Result 'D' 'dry run of Snapshot does not create the snapshot folder' (-not (Test-Path -LiteralPath $emptySnapRoot))
    $r = Invoke-Script $setIndexState @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot, '-DryRun') $goodCs
    Add-Result 'D' 'dry run of RemoveIndexes without -Execute says that the real run stops before the change' ($r.Output.Contains('Without -Execute: stop after the gates and print the approval code. The schema is not changed.'))

    # ---- D8. static: the normal path cannot reach `database update` -----------------------------------------------------------------------------
    $entryText = Get-Content -LiteralPath $setIndexState -Raw
    $libText = Get-Content -LiteralPath (Join-Path $perfDir 'perf-schema-step.ps1') -Raw
    $allPerfScripts = Get-ChildItem -LiteralPath $perfDir -Filter *.ps1 | Where-Object { $_.Name -ne 'test-perf-scripts.ps1' }
    $updateTokens = @($allPerfScripts | ForEach-Object { [regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw), "'database'\s*,\s*'update'") | ForEach-Object { $_.Value } })
    Add-Result 'D' "the tokens 'database', 'update' (an EF update command) exist only inside Get-EfUpdateArguments of perf-schema-step.ps1" (
        ($updateTokens.Count -eq 2) -and ([regex]::Matches($libText, "'database'\s*,\s*'update'").Count -eq 2) -and ($libText -match "(?s)function Get-EfUpdateArguments.*?'database', 'update', 'InitialCreate'.*?'database', 'update'\)"))
    $callers = @($allPerfScripts | ForEach-Object { $t = Get-Content -LiteralPath $_.FullName -Raw; [regex]::Matches($t, 'Get-EfUpdateArguments').Count - [regex]::Matches($t, 'function Get-EfUpdateArguments').Count } | Where-Object { $_ -gt 0 })
    Add-Result 'D' 'Get-EfUpdateArguments is called from exactly one place, inside Invoke-EfDatabaseUpdate' (($callers.Count -eq 1) -and ($callers[0] -eq 1) -and ($libText -match '(?s)function Invoke-EfDatabaseUpdate.*?Get-EfUpdateArguments \$Action'))
    Add-Result 'D' 'Invoke-EfDatabaseUpdate checks for an unused grant of the same action BEFORE it marks it used and before it starts anything' (
        ($libText -match '(?s)function Invoke-EfDatabaseUpdate.*?APPROVAL_REQUIRED.*?APPROVAL_ACTION_MISMATCH.*?\$grant\.Used = \$true.*?Invoke-ChildProcess'))
    Add-Result 'D' 'set-index-state.ps1 calls Invoke-EfDatabaseUpdate exactly once, inside Invoke-StepChange, after Grant-SchemaChangeApproval and after the stop-before-change branch' (
        ([regex]::Matches($entryText, 'Invoke-EfDatabaseUpdate').Count -eq 1) -and ([regex]::Matches($entryText, 'Grant-SchemaChangeApproval').Count -eq 1) -and
        ($entryText.IndexOf('if (-not $Execute) {') -gt 0) -and ($entryText.IndexOf('if (-not $Execute) {') -lt $entryText.IndexOf('Grant-SchemaChangeApproval')) -and ($entryText.IndexOf('Grant-SchemaChangeApproval') -lt $entryText.IndexOf('Invoke-EfDatabaseUpdate')) -and
        ($entryText -match '(?s)function Invoke-StepChange.*?Invoke-EfDatabaseUpdate'))
    $stopBranch = $entryText.Substring($entryText.IndexOf('if (-not $Execute) {'), $entryText.IndexOf('Grant-SchemaChangeApproval') - $entryText.IndexOf('if (-not $Execute) {'))
    Add-Result 'D' 'the stop-before-change branch ends in exit 0 before the grant' ($stopBranch -match 'exit 0')
    $snapshotBranch = $entryText.Substring($entryText.IndexOf('# ---- ACTION: Snapshot'), $entryText.IndexOf('# ---- ACTION: RemoveIndexes') - $entryText.IndexOf('# ---- ACTION: Snapshot'))
    Add-Result 'D' 'the Snapshot and Check branches contain no reference to the change, the grant or the update' ($snapshotBranch -notmatch 'Invoke-StepChange|Invoke-EfDatabaseUpdate|Grant-SchemaChangeApproval|database update')
    Add-Result 'D' 'Invoke-StepChange is called only for RemoveIndexes and RestoreIndexes' (
        ([regex]::Matches($entryText, "(?m)^if \(\`$Action -eq '(RemoveIndexes|RestoreIndexes)'\) \{ Invoke-StepChange").Count -eq 2) -and ([regex]::Matches($entryText, 'Invoke-StepChange').Count -eq 3))
    $beforeReal = $entryText.Substring(0, $entryText.IndexOf('# ---- 3. real run'))
    Add-Result 'D' 'before the real-run section nothing starts a process, resolves a tool or connects (so -DryRun cannot)' ($beforeReal -notmatch 'Invoke-ChildProcess|Invoke-PerfSqlcmd|Invoke-ServerGuard|Resolve-PerfTool|New-PerfWorkDir|Start-Process|Invoke-EfDatabaseUpdate|Get-LiveState')
    Add-Result 'D' 'the real run takes the guard approval before dotnet, the state query and the change (gates in order)' (
        ($entryText.IndexOf('Invoke-ServerGuard $builder') -gt 0) -and ($entryText.IndexOf('Invoke-ServerGuard $builder') -lt $entryText.IndexOf("'dbcontext', 'info'")) -and ($entryText.IndexOf("'dbcontext', 'info'") -lt $entryText.IndexOf("'migrations', 'script'")) -and
        ($entryText.IndexOf("'migrations', 'script'") -lt $entryText.IndexOf('$state1 = Get-LiveState')))
    Add-Result 'D' 'the change is followed by a fresh read of the state and a refusal on any mismatch, and nothing is repaired' (
        ($entryText -match '(?s)Invoke-EfDatabaseUpdate.*?\$after = Get-LiveState.*?POST_CHECK_FAILED') -and ($entryText -match 'EF_UPDATE_FAILED') -and ($entryText -notmatch 'Seeder|--reset|DROP |CREATE INDEX'))
    Add-Result 'D' 'set-index-state.ps1 sends no SQL text (only the SchemaState kind), starts only dotnet through the wrapper, and has the trap and -KeepWorkOnFailure' (
        ($entryText -notmatch 'Invoke-PerfSqlcmd[^\r\n]*-Sql\b') -and ($entryText -match '-Kind SchemaState') -and ($entryText -notmatch 'Start-Process') -and ($entryText -match '(?m)^trap \{ Invoke-PerfFailureCleanup; break \}') -and ($entryText -match '\[switch\]\$KeepWorkOnFailure'))

    # ---- D9. the human confirmation: a change cannot be completed by a run without an interactive console ------------------------------------------
    $readCounter = @{ Calls = 0 }
    function New-Typist($Text) { $readCounter.Calls = 0; $counter = $readCounter; { $counter.Calls++; $Text }.GetNewClosure() }
    $phrase = Get-StepConfirmationPhrase 'RemoveIndexes' $code
    Add-Result 'D' 'confirmation sentence names the action, the exact database and the approval code' (
        $phrase.Contains('RemoveIndexes') -and $phrase.Contains('RequestManagement_Perf') -and $phrase.Contains($code) -and
        ($phrase -cne (Get-StepConfirmationPhrase 'RestoreIndexes' $code)) -and ($phrase -cne (Get-StepConfirmationPhrase 'RemoveIndexes' 'AAAAAAAAAAAA')))
    $reader = New-Typist $phrase
    Add-Result 'D' 'confirmation: redirected input stops with HUMAN_CONFIRMATION_REQUIRED and never reads' (((Get-StopCode { Confirm-StepByHuman 'RemoveIndexes' $code $true $false $reader }) -eq 'HUMAN_CONFIRMATION_REQUIRED') -and ($readCounter.Calls -eq 0))
    $reader = New-Typist $phrase
    Add-Result 'D' 'confirmation: redirected output stops with HUMAN_CONFIRMATION_REQUIRED even with the right sentence available' (((Get-StopCode { Confirm-StepByHuman 'RemoveIndexes' $code $false $true $reader }) -eq 'HUMAN_CONFIRMATION_REQUIRED') -and ($readCounter.Calls -eq 0))
    $reader = New-Typist $phrase
    Add-Result 'D' 'confirmation: both redirected stops with HUMAN_CONFIRMATION_REQUIRED' ((Get-StopCode { Confirm-StepByHuman 'RemoveIndexes' $code $true $true $reader }) -eq 'HUMAN_CONFIRMATION_REQUIRED')
    foreach ($wrong in @(
            @('empty line', ''), @('only the code', $code), @('yes', 'yes'), @('lower case', $phrase.ToLowerInvariant()),
            @('the other action', (Get-StepConfirmationPhrase 'RestoreIndexes' $code)), @('another code', (Get-StepConfirmationPhrase 'RemoveIndexes' 'AAAAAAAAAAAA')),
            @('the development database', $phrase.Replace('RequestManagement_Perf', 'RequestManagement')), @('an extra word', "$phrase now"), @('end of input (null)', $null))) {
        $reader = New-Typist $wrong[1]
        Add-Result 'D' "confirmation: a wrong sentence stops with HUMAN_CONFIRMATION_MISMATCH ($($wrong[0]))" ((Get-StopCode { Confirm-StepByHuman 'RemoveIndexes' $code $false $false $reader }) -eq 'HUMAN_CONFIRMATION_MISMATCH')
    }
    $reader = New-Typist $phrase
    Add-Result 'D' 'confirmation: the exact sentence typed at an interactive console passes' ((Get-StopCode { Confirm-StepByHuman 'RemoveIndexes' $code $false $false $reader }) -eq 'NONE')
    $reader = New-Typist "  $phrase  "
    Add-Result 'D' 'confirmation: surrounding white space is tolerated, nothing else' ((Get-StopCode { Confirm-StepByHuman 'RemoveIndexes' $code $false $false $reader }) -eq 'NONE')
    $changeBody = $entryText.Substring($entryText.IndexOf('function Invoke-StepChange'))
    Add-Result 'D' 'Invoke-StepChange order: code check (grant), then the human confirmation, then the fresh state read, then the one update command' (
        ([regex]::Matches($entryText, 'Confirm-StepByHuman').Count -eq 1) -and
        ($changeBody.IndexOf('Grant-SchemaChangeApproval') -lt $changeBody.IndexOf('Confirm-StepByHuman')) -and
        ($changeBody.IndexOf('Confirm-StepByHuman') -lt $changeBody.IndexOf('$recheck = Get-LiveState')) -and
        ($changeBody.IndexOf('$recheck = Get-LiveState') -lt $changeBody.IndexOf('Invoke-EfDatabaseUpdate')))
    Add-Result 'D' 'the real console check reads [Console]::IsInputRedirected, [Console]::IsOutputRedirected and [Console]::In, with no parameter or variable that skips it' (
        $entryText.Contains('Confirm-StepByHuman $ChangeAction $code ([Console]::IsInputRedirected) ([Console]::IsOutputRedirected) { [Console]::In.ReadLine() }') -and
        ($entryText -notmatch '(?i)\[switch\]\$(Yes|Force|Confirm|NoPrompt|AssumeYes|Auto)') -and ($entryText -notmatch 'Read-Host'))
    Add-Result 'D' 'Confirm-StepByHuman checks redirection before it prints or reads anything' (
        $libText -match '(?s)function Confirm-StepByHuman.*?if \(\$InputRedirected -or \$OutputRedirected\) \{.*?HUMAN_CONFIRMATION_REQUIRED.*?\}.*?& \$ReadLine')
    $r = Invoke-Script $setIndexState @('-Action', 'RemoveIndexes', '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-ApprovalCode', $goodCode, '-SnapshotRoot', $snapRoot, '-DryRun') $goodCs
    Add-Result 'D' 'dry run of -Execute says that a person must type a confirmation sentence and still starts nothing' ($r.Output.Contains('a person must then type a confirmation sentence') -and ($r.Started.Count -eq 0) -and ($r.Exit -eq 0))

    # ============================================================================================================
    # E. set-index-state.ps1 from start to finish against FAKE docker, sqlcmd and dotnet programs (offline)
    #    The fakes are one tiny compiled program, copied under three names, that answers from files and writes every call to a log.
    #    `dotnet ef database update` has no answer in any world: if it were ever started, it would be logged and would fail.
    # ============================================================================================================
    $fakeBin = Join-Path $tempRoot 'fakebin'
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $fakeSource = @'
using System;
using System.IO;
public static class T501Fake {
    public static int Main(string[] args) {
        string tool = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        string dir = Environment.GetEnvironmentVariable("T501_FAKE_DIR");
        string log = Environment.GetEnvironmentVariable("T501_FAKE_LOG");
        string joined = string.Join(" ", args);
        string envNames = "";
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) {
            string k = e.Key.ToString();
            if (k.StartsWith("SQLCMD", StringComparison.OrdinalIgnoreCase)) envNames += (envNames.Length > 0 ? "," : "") + k;
        }
        if (!string.IsNullOrEmpty(log)) File.AppendAllText(log, tool + " " + joined + " [env:" + envNames + "]\r\n");
        if (string.IsNullOrEmpty(dir)) { Console.Error.WriteLine("FAKE: T501_FAKE_DIR is not set"); return 98; }
        string rules = Path.Combine(dir, tool + ".rules");
        if (File.Exists(rules)) {
            foreach (string line in File.ReadAllLines(rules)) {
                string[] p = line.Split('\t');
                if (p.Length < 3 || p[0].Length == 0) continue;
                if (joined.Contains(p[0])) {
                    string file = Path.Combine(dir, p[2]);
                    if (File.Exists(file)) Console.Out.Write(File.ReadAllText(file));
                    return int.Parse(p[1]);
                }
            }
        }
        Console.Error.WriteLine("FAKE: no answer for " + tool + " " + joined);
        return 97;
    }
}
'@
    Add-Type -TypeDefinition $fakeSource -OutputAssembly (Join-Path $fakeBin 'dotnet.exe') -OutputType ConsoleApplication
    foreach ($n in @('docker', 'sqlcmd')) { Copy-Item -LiteralPath (Join-Path $fakeBin 'dotnet.exe') -Destination (Join-Path $fakeBin "$n.exe") }
    $fakeCounter = @{ N = 0 }
    $updateCalls = New-Object System.Collections.Generic.List[string]
    $efContextGood = "Provider name: Microsoft.EntityFrameworkCore.SqlServer`nDatabase name: RequestManagement_Perf`nData source: localhost,1433`nOptions: None`n"

    # One "world": what the fake tools answer. $State is the output of the state query; $Set overrides any default below.
    function New-FakeWorld([string[]]$State = $withLines, [hashtable]$Set = @{}) {
        $fakeCounter.N++
        $dir = Join-Path $tempRoot "fake-world-$($fakeCounter.N)"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $v = @{ DockerInspect = 'running/healthy'; DockerPort = '0.0.0.0:1433'; GuardExists = '1'; GuardMarker = '1'; GuardExit = 0; StateExit = 0
            EfContext = $efContextGood; EfContextExit = 0; EfDown = $down; EfUp = $up }
        foreach ($k in $Set.Keys) { $v[$k] = $Set[$k] }
        $files = @{ 'docker-inspect.txt' = $v.DockerInspect; 'docker-port.txt' = $v.DockerPort; 'guard-exists.txt' = $v.GuardExists; 'guard-marker.txt' = $v.GuardMarker
            'state.txt' = (@($State) -join "`r`n"); 'ef-context.txt' = $v.EfContext; 'ef-down.txt' = $v.EfDown; 'ef-up.txt' = $v.EfUp }
        foreach ($name in $files.Keys) { [IO.File]::WriteAllText((Join-Path $dir $name), [string]$files[$name]) }
        [IO.File]::WriteAllText((Join-Path $dir 'docker.rules'), "inspect`t0`tdocker-inspect.txt`nport`t0`tdocker-port.txt`n")
        [IO.File]::WriteAllText((Join-Path $dir 'sqlcmd.rules'), "FROM sys.databases WHERE name`t$($v.GuardExit)`tguard-exists.txt`nsys.extended_properties`t$($v.GuardExit)`tguard-marker.txt`n-d RequestManagement_Perf`t$($v.StateExit)`tstate.txt`n")
        [IO.File]::WriteAllText((Join-Path $dir 'dotnet.rules'), "dbcontext info`t$($v.EfContextExit)`tef-context.txt`nmigrations script AddQueryIndexes InitialCreate`t0`tef-down.txt`nmigrations script InitialCreate AddQueryIndexes`t0`tef-up.txt`n")
        [pscustomobject]@{ Dir = $dir; Log = (Join-Path $dir 'fake.log') }
    }

    function Invoke-FakeRun([string[]]$Arguments, $World) {
        $oldPath = $env:PATH
        try {
            $env:PATH = "$fakeBin;$oldPath"
            [Environment]::SetEnvironmentVariable('T501_FAKE_DIR', $World.Dir, 'Process')
            [Environment]::SetEnvironmentVariable('T501_FAKE_LOG', $World.Log, 'Process')
            $run = Invoke-Script $setIndexState $Arguments $goodCs
        }
        finally {
            $env:PATH = $oldPath
            [Environment]::SetEnvironmentVariable('T501_FAKE_DIR', $null, 'Process')
            [Environment]::SetEnvironmentVariable('T501_FAKE_LOG', $null, 'Process')
        }
        $calls = if (Test-Path -LiteralPath $World.Log) { @(Get-Content -LiteralPath $World.Log) } else { @() }
        foreach ($c in @($calls + $run.Started)) { if ($c -match 'database\s+update|\bef\s+database\b') { $updateCalls.Add($c) } }
        Add-Member -InputObject $run -NotePropertyName FakeCalls -NotePropertyValue $calls -PassThru
    }

    # A run behaved as expected: exit code, the lines it must print, the lines it must not, no secret, no change.
    function Test-FakeRun($Run, [int]$Exit, [string[]]$Contains, [string[]]$NotContains = @()) {
        $ok = ($Run.Exit -eq $Exit) -and -not $Run.Output.Contains($fake) -and -not $Run.Output.Contains('Password=') -and -not $Run.Output.Contains('CHANGE OK') -and
            (@(@($Run.FakeCalls) + @($Run.Started) | Where-Object { $_ -match 'database\s+update' }).Count -eq 0) -and (@($Run.FakeCalls | Where-Object { $_ -match "$([regex]::Escape($fake))" }).Count -eq 0)
        foreach ($c in $Contains) { if (-not $Run.Output.Contains($c)) { $ok = $false } }
        foreach ($c in $NotContains) { if ($Run.Output.Contains($c)) { $ok = $false } }
        $ok
    }
    function Get-FakeCode([string]$Output) { if ($Output -match '(?m)Approval code for [^\r\n:]*: ([0-9A-F]{12})') { $matches[1] } else { '' } }
    $zeroCode = '000000000000'
    $execArgs = { param($action, $code) @('-Action', $action, '-Execute', '-ConfirmDatabase', 'RequestManagement_Perf', '-ApprovalCode', $code, '-SnapshotRoot', $snapRoot) }
    $resultsTreeBefore = Get-TreeSnapshot (Join-Path $perfDir 'results')
    $defaultSnapshotsExisted = Test-Path -LiteralPath (Join-Path $perfDir 'snapshots')

    # ---- E0. control: the log catches `database update`, and the fake cannot answer it ----------------------------------------------------------
    $w = New-FakeWorld
    $oldDir = $env:T501_FAKE_DIR; $oldLog = $env:T501_FAKE_LOG
    $env:T501_FAKE_DIR = $w.Dir; $env:T501_FAKE_LOG = $w.Log
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $controlOut = (& (Join-Path $fakeBin 'dotnet.exe') ef database update InitialCreate 2>&1 | Out-String); $controlExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previousPreference }
    $env:T501_FAKE_DIR = $oldDir; $env:T501_FAKE_LOG = $oldLog
    Add-Result 'E' 'control: the fake dotnet fails `ef database update` (exit 97) and logs it in a form the detector recognises' (($controlExit -eq 97) -and (@(Get-Content -LiteralPath $w.Log) -match 'database\s+update').Count -eq 1) $controlOut

    # ---- E1. the normal path: gates pass, and the run stops before the change --------------------------------------------------------------------
    $worldWith = New-FakeWorld
    $worldWithout = New-FakeWorld (Drop-Lines (Drop-Lines $withLines 'index|Requests|IX_Requests_*') 'migration|20261020183100_AddQueryIndexes|*')
    $rCheck = Invoke-FakeRun @('-Action', 'Check', '-SnapshotRoot', $snapRoot) $worldWith
    Add-Result 'E' 'Check on the expected state: exits 0, passes all six gates, prints the RemoveIndexes code, changes nothing' (Test-FakeRun $rCheck 0 @('Gate 2 ok', 'Gate 3 ok', 'Gate 4 ok', 'Gate 5 ok', 'Gate 6 ok', 'Approval code for -Action RemoveIndexes', 'CHECK OK - nothing was changed'))
    Add-Result 'E' 'Check: the fake tools were really used (control: dbcontext info, both migration scripts, the guard and the state query)' (
        (@($rCheck.FakeCalls | Where-Object { $_ -match '^dotnet .*dbcontext info' }).Count -eq 1) -and (@($rCheck.FakeCalls | Where-Object { $_ -match '^dotnet .*migrations script' }).Count -eq 2) -and
        (@($rCheck.FakeCalls | Where-Object { $_ -match '^docker inspect' }).Count -eq 1) -and (@($rCheck.FakeCalls | Where-Object { $_ -match '^sqlcmd .* -d RequestManagement_Perf ' }).Count -eq 1))
    $removeCode = Get-FakeCode $rCheck.Output
    $rRemove = Invoke-FakeRun @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot) $worldWith
    Add-Result 'E' 'RemoveIndexes without -Execute: exits 0 and STOPS BEFORE THE CHANGE, printing the code; no `database update`' (Test-FakeRun $rRemove 0 @('Gate 6 ok', 'STOPPED BEFORE THE CHANGE, as designed', 'Approval code for exactly this verified state: ') @('Approval code accepted', 'Running the one schema-changing command'))
    Add-Result 'E' 'the code printed by Check and by RemoveIndexes is the same 12-character code of the same state' (($removeCode -cmatch '^[0-9A-F]{12}$') -and ($removeCode -ceq (Get-FakeCode $rRemove.Output)))
    $rCheckWithout = Invoke-FakeRun @('-Action', 'Check', '-SnapshotRoot', $snapRoot) $worldWithout
    Add-Result 'E' 'Check on the state without the five indexes: exits 0 and prints the RestoreIndexes code' (Test-FakeRun $rCheckWithout 0 @('expected state WithoutIndexes', 'Approval code for -Action RestoreIndexes'))
    $restoreCode = Get-FakeCode $rCheckWithout.Output
    $rRestore = Invoke-FakeRun @('-Action', 'RestoreIndexes', '-SnapshotRoot', $snapRoot) $worldWithout
    Add-Result 'E' 'RestoreIndexes without -Execute: exits 0 and STOPS BEFORE THE CHANGE (the mirror image)' (Test-FakeRun $rRestore 0 @('STOPPED BEFORE THE CHANGE, as designed') @('Approval code accepted', 'Running the one schema-changing command'))
    Add-Result 'E' 'the removal code and the restoration code differ' (($restoreCode -cmatch '^[0-9A-F]{12}$') -and ($restoreCode -cne $removeCode))

    # ---- E2. the approval gate: a correct code is still not enough without a person at a console; a wrong one stops earlier ------------------------
    $rExecRemove = Invoke-FakeRun (& $execArgs 'RemoveIndexes' $removeCode) $worldWith
    Add-Result 'E' 'RemoveIndexes -Execute with the right code, but no interactive console: stops with HUMAN_CONFIRMATION_REQUIRED, no `database update`' (Test-FakeRun $rExecRemove 1 @('[HUMAN_CONFIRMATION_REQUIRED]', 'Approval code accepted for this action') @('Confirmation sentence accepted', 'Running the one schema-changing command'))
    $rExecRestore = Invoke-FakeRun (& $execArgs 'RestoreIndexes' $restoreCode) $worldWithout
    Add-Result 'E' 'RestoreIndexes -Execute with the right code, but no interactive console: stops with HUMAN_CONFIRMATION_REQUIRED' (Test-FakeRun $rExecRestore 1 @('[HUMAN_CONFIRMATION_REQUIRED]') @('Confirmation sentence accepted', 'Running the one schema-changing command'))
    foreach ($case in @(
            @('a wrong code', 'RemoveIndexes', $zeroCode, $worldWith, '[APPROVAL_CODE_MISMATCH]'),
            @('the code of the other action', 'RemoveIndexes', $restoreCode, $worldWith, '[APPROVAL_CODE_MISMATCH]'),
            @('the removal code used for the restoration', 'RestoreIndexes', $removeCode, $worldWithout, '[APPROVAL_CODE_MISMATCH]'),
            @('the restoration while the indexes are still there', 'RestoreIndexes', $restoreCode, $worldWith, '[GATE_FAILED]'))) {
        $rr = Invoke-FakeRun (& $execArgs $case[1] $case[2]) $case[3]
        Add-Result 'E' "-Execute $($case[1]) with $($case[0]): stops with $($case[4]) before any confirmation or command" (Test-FakeRun $rr 1 @($case[4]) @('Approval code accepted', 'Confirmation sentence accepted', 'Running the one schema-changing command')) "exit $($rr.Exit)"
    }
    $rWrongState = Invoke-FakeRun @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot) $worldWithout
    Add-Result 'E' 'RemoveIndexes when the indexes are already gone: GATE_FAILED, nothing proposed' (Test-FakeRun $rWrongState 1 @('[GATE_FAILED]') @('STOPPED BEFORE THE CHANGE', 'Approval code for'))
    $rWrongState = Invoke-FakeRun @('-Action', 'RestoreIndexes', '-SnapshotRoot', $snapRoot) $worldWith
    Add-Result 'E' 'RestoreIndexes when the indexes are still there: GATE_FAILED, nothing proposed' (Test-FakeRun $rWrongState 1 @('[GATE_FAILED]') @('STOPPED BEFORE THE CHANGE', 'Approval code for'))

    # ---- E3. the state gates, run through the real script (with -Execute and a well-formed code: still nothing is accepted) ------------------------
    $liveCases = @('wrong database (the development database)', 'marker missing', 'database offline', 'database read-only', 'too few rows', 'wrong checksum', 'distribution by status changed',
        'history rows appeared', 'AddQueryIndexes missing from the history', 'an extra migration', 'one of the five indexes missing', 'an index option altered (fill factor)', 'an unknown extra index on Requests',
        'another session on the database', 'an error message among the lines', 'an empty answer')
    foreach ($name in $liveCases) {
        $gc = @($gateCases | Where-Object { $_[0] -ceq $name })[0]
        $rr = Invoke-FakeRun (& $execArgs 'RemoveIndexes' $zeroCode) (New-FakeWorld $gc[2])
        Add-Result 'E' "live state gate, RemoveIndexes -Execute: $name -> GATE_FAILED before any approval" (Test-FakeRun $rr 1 @('[GATE_FAILED]') @('Approval code accepted', 'STOPPED BEFORE THE CHANGE', 'Running the one schema-changing command')) "exit $($rr.Exit)"
    }
    foreach ($name in @('wrong checksum', 'marker missing')) {
        $gc = @($gateCases | Where-Object { $_[0] -ceq $name })[0]
        $rr = Invoke-FakeRun @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot) (New-FakeWorld $gc[2])
        Add-Result 'E' "live state gate, RemoveIndexes (default): $name -> GATE_FAILED, no code printed" (Test-FakeRun $rr 1 @('[GATE_FAILED]') @('STOPPED BEFORE THE CHANGE', 'Approval code for'))
        $rr = Invoke-FakeRun @('-Action', 'Check', '-SnapshotRoot', $snapRoot) (New-FakeWorld $gc[2])
        Add-Result 'E' "live state gate, Check: $name -> stops, no code printed" (Test-FakeRun $rr 1 @('[GATE_FAILED]') @('Approval code for', 'CHECK OK'))
    }
    $rr = Invoke-FakeRun @('-Action', 'RestoreIndexes', '-SnapshotRoot', $snapRoot) (New-FakeWorld (Edit-Lines (Drop-Lines (Drop-Lines $withLines 'index|Requests|IX_Requests_*') 'migration|20261020183100_AddQueryIndexes|*') 'dataset|*' '-1953119262' '-1953119261'))
    Add-Result 'E' 'live state gate, RestoreIndexes: a wrong checksum in the state without the indexes -> GATE_FAILED' (Test-FakeRun $rr 1 @('[GATE_FAILED]') @('STOPPED BEFORE THE CHANGE'))
    $rr = Invoke-FakeRun @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot) (New-FakeWorld $liveChangedHistoryIndex)
    Add-Result 'E' 'live state gate: a difference from the snapshot that no fixed rule covers (history index option) -> GATE_FAILED' (Test-FakeRun $rr 1 @('[GATE_FAILED]', 'differs from the snapshot') @('STOPPED BEFORE THE CHANGE'))
    $rr = Invoke-FakeRun @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot) (New-FakeWorld $withLines @{ StateExit = 1 })
    Add-Result 'E' 'the state query fails (for example the database is gone): SQLCMD_FAILED, nothing proposed' (Test-FakeRun $rr 1 @('[SQLCMD_FAILED]') @('STOPPED BEFORE THE CHANGE'))

    # ---- E4. the server gates: container, port, database, marker -----------------------------------------------------------------------------------
    foreach ($case in @(
            @('the container exited', @{ DockerInspect = 'exited/' }), @('the container is unhealthy', @{ DockerInspect = 'running/unhealthy' }), @('the container is paused', @{ DockerInspect = 'paused/healthy' }),
            @('the container does not publish port 1433', @{ DockerPort = '0.0.0.0:1444' }), @('the T501_PERF_DB marker is absent', @{ GuardMarker = '0' }),
            @('the guard cannot query the server', @{ GuardExit = 1 }), @('the guard gets an unexpected answer', @{ GuardExists = '2' }))) {
        foreach ($action in @('Check', 'RemoveIndexes')) {
            $rr = Invoke-FakeRun @('-Action', $action, '-SnapshotRoot', $snapRoot) (New-FakeWorld $withLines $case[1])
            Add-Result 'E' "server gate, $action : $($case[0]) -> GUARD_FAILED, nothing else was started" (
                (Test-FakeRun $rr 1 @('[GUARD_FAILED]', 'GUARD: STOP') @('Gate 3 ok', 'STOPPED BEFORE THE CHANGE', 'Approval code for')) -and (@($rr.FakeCalls | Where-Object { $_ -match '^dotnet ' }).Count -eq 0) -and (@($rr.FakeCalls | Where-Object { $_ -match '-d RequestManagement_Perf' }).Count -eq 0)) "exit $($rr.Exit)"
        }
    }

    # ---- E5. the Entity Framework gates: wrong context, SQL that is not the expected text ---------------------------------------------------------------
    foreach ($case in @(
            @('the context points at the development database', @{ EfContext = $efContextGood.Replace('RequestManagement_Perf', 'RequestManagement') }, 'EF_TARGET_MISMATCH'),
            @('the context points at another server', @{ EfContext = $efContextGood.Replace('localhost,1433', 'sql.example.com,1433') }, 'EF_TARGET_MISMATCH'),
            @('dotnet ef dbcontext info fails', @{ EfContextExit = 1 }, 'EF_TARGET_MISMATCH'),
            @('the removal SQL has an extra DROP TABLE', @{ EfDown = ($down + "`nDROP TABLE [Requests];") }, 'EF_SQL_MISMATCH'),
            @('the removal SQL lacks one DROP INDEX', @{ EfDown = ($down -replace 'DROP INDEX \[IX_Requests_Priority_Status\] ON \[Requests\];', '') }, 'EF_SQL_MISMATCH'),
            @('the restoration SQL lacks an INCLUDE', @{ EfUp = ($up -replace ' INCLUDE \(\[Priority\]\)', '') }, 'EF_SQL_MISMATCH'),
            @('the restoration SQL is empty', @{ EfUp = '' }, 'EF_SQL_MISMATCH'))) {
        $rr = Invoke-FakeRun (& $execArgs 'RemoveIndexes' $zeroCode) (New-FakeWorld $withLines $case[1])
        Add-Result 'E' "EF gate: $($case[0]) -> $($case[2]), before the state is even read" (Test-FakeRun $rr 1 @("[$($case[2])]") @('Approval code accepted', 'STOPPED BEFORE THE CHANGE') ) "exit $($rr.Exit)"
    }

    # ---- E6. the Snapshot action (the baseline), against the fakes: create-only, nothing but SELECT-shaped calls, no secrets -------------------------------
    $fakeSnapRoot = Join-Path $tempRoot 'fake-snap-root'
    $rr = Invoke-FakeRun @('-Action', 'Snapshot', '-SnapshotRoot', $fakeSnapRoot) (New-FakeWorld)
    $fakeSnapFile = Join-Path $fakeSnapRoot 'RequestManagement_Perf.pre-step2.txt'
    Add-Result 'E' 'Snapshot: exits 0 and writes RequestManagement_Perf.pre-step2.txt outside docs/perf/results' ((Test-FakeRun $rr 0 @('SNAPSHOT OK', 'The database was only read')) -and (Test-Path -LiteralPath $fakeSnapFile))
    $fakeSnapText = if (Test-Path -LiteralPath $fakeSnapFile) { Get-Content -LiteralPath $fakeSnapFile -Raw } else { '' }
    $fakeSnapState = if ($fakeSnapText) { Read-StepSnapshot $fakeSnapFile } else { $null }
    Add-Result 'E' 'Snapshot file: marker, 100000 rows, checksum, distributions, migrations and every index are recorded; no password or connection string' (
        $fakeSnapText.Contains('dataset|rows=100000|checksum=-1953119262') -and $fakeSnapText.Contains('marker=1') -and $fakeSnapText.Contains('by_status|1|19831') -and $fakeSnapText.Contains('by_priority|3|14829') -and
        $fakeSnapText.Contains('migration|20261020183100_AddQueryIndexes|') -and ([regex]::Matches($fakeSnapText, '(?m)^index\|').Count -eq 9) -and ($fakeSnapText -notmatch '(?i)password|pwd=|User Id|Server=') -and -not $fakeSnapText.Contains($fake) -and
        ($null -ne $fakeSnapState) -and (@(Get-StepGateFailures $fakeSnapState 'WithIndexes').Count -eq 0))
    $fakeSnapBefore = Get-TreeSnapshot $fakeSnapRoot
    $rr = Invoke-FakeRun @('-Action', 'Snapshot', '-SnapshotRoot', $fakeSnapRoot) (New-FakeWorld)
    Add-Result 'E' 'Snapshot: a second run does not replace the snapshot (RESULTS_EXIST)' ((Test-FakeRun $rr 1 @('[RESULTS_EXIST]')) -and ((Get-TreeSnapshot $fakeSnapRoot) -ceq $fakeSnapBefore))
    $badSnapRoot2 = Join-Path $tempRoot 'fake-snap-root-bad'
    $rr = Invoke-FakeRun @('-Action', 'Snapshot', '-SnapshotRoot', $badSnapRoot2) (New-FakeWorld (Edit-Lines $withLines 'dataset|*' '-1953119262' '-1953119261'))
    Add-Result 'E' 'Snapshot: a state with a wrong checksum is never recorded (GATE_FAILED, no file, no folder)' ((Test-FakeRun $rr 1 @('[GATE_FAILED]') @('SNAPSHOT OK')) -and -not (Test-Path -LiteralPath $badSnapRoot2))
    $rr = Invoke-FakeRun @('-Action', 'Snapshot', '-SnapshotRoot', $badSnapRoot2) (New-FakeWorld (Edit-Lines $withLines 'target|*' 'marker=1' 'marker=0'))
    Add-Result 'E' 'Snapshot: a database without the marker is never recorded' ((Test-FakeRun $rr 1 @('[GATE_FAILED]') @('SNAPSHOT OK')) -and -not (Test-Path -LiteralPath $badSnapRoot2))
    $roundTrip = Invoke-FakeRun @('-Action', 'Check', '-SnapshotRoot', $fakeSnapRoot) (New-FakeWorld)
    Add-Result 'E' 'a snapshot taken by the script is accepted by the later gates (Check against it, same state, same code family)' (Test-FakeRun $roundTrip 0 @('CHECK OK', 'Approval code for -Action RemoveIndexes'))

    # ---- E6a. partial states, as the script reports them; restoration does not depend on how the removal ended -----------------------------------------
    $partialWorlds = @(
        @('four of five indexes (a removal that stopped half way)', (Drop-Lines $withLines "index|Requests|$oneIx|*"), 'PARTIAL_SOME_INDEXES'),
        @('no index, history row still there', (Drop-Lines $withLines $allIxLike), 'INDEXES_GONE_HISTORY_PRESENT'),
        @('all indexes, history row gone (a restoration that stopped before the history row)', (Drop-Lines $withLines $historyLike), 'INDEXES_PRESENT_HISTORY_MISSING'),
        @('two indexes recreated, history row gone', ($withoutLines + @($ixLines[0], $ixLines[1])), 'PARTIAL_SOME_INDEXES_HISTORY_MISSING'),
        @('an index with another option', (Edit-Lines $withLines 'index|Requests|IX_Requests_Priority_Status|*' 'fill=0' 'fill=90'), 'INDEX_ALTERED'),
        @('the data changed', (Edit-Lines $withLines 'dataset|*' '-1953119262' '-1953119261'), 'DATA_OR_TARGET_DIFFERS'))
    foreach ($case in $partialWorlds) {
        foreach ($act in @(@('Check', @('-Action', 'Check', '-SnapshotRoot', $snapRoot)), @('RemoveIndexes', @('-Action', 'RemoveIndexes', '-SnapshotRoot', $snapRoot)), @('RestoreIndexes', @('-Action', 'RestoreIndexes', '-SnapshotRoot', $snapRoot)))) {
            $rr = Invoke-FakeRun $act[1] (New-FakeWorld $case[1])
            Add-Result 'E' "partial state '$($case[0])', $($act[0]): GATE_FAILED with Classification $($case[2]); no code, no change" (Test-FakeRun $rr 1 @('[GATE_FAILED]', "Classification: $($case[2])", 'Nothing was changed by this run') @('Approval code for', 'STOPPED BEFORE THE CHANGE', 'CHECK OK')) "exit $($rr.Exit)"
        }
    }
    $rr = Invoke-FakeRun @('-Action', 'RestoreIndexes', '-SnapshotRoot', $snapRoot) (New-FakeWorld (Drop-Lines (Drop-Lines $withLines $allIxLike) $historyLike))
    Add-Result 'E' 'RestoreIndexes from the state without the indexes stops before the change: the gates use only the live state and the snapshot, not the outcome of any earlier run' (
        (Test-FakeRun $rr 0 @('Gate 6 ok', 'STOPPED BEFORE THE CHANGE')))

    foreach ($case in @(@('all five indexes, no history row', (Drop-Lines $withLines $historyLike), 'Do not add the row by hand'), @('some indexes, no history row', ($withoutLines + @($ixLines[0], $ixLines[1])), 'Do not add the history row by hand'))) {
        foreach ($act in @(@('Check', @('-Action', 'Check', '-SnapshotRoot', $snapRoot)), @('RestoreIndexes', @('-Action', 'RestoreIndexes', '-SnapshotRoot', $snapRoot)), @('RestoreIndexes -Execute', (& $execArgs 'RestoreIndexes' $zeroCode)))) {
            $rr = Invoke-FakeRun $act[1] (New-FakeWorld $case[1])
            Add-Result 'E' "history missing ($($case[0])), $($act[0]): exit 1 GATE_FAILED, 'STOP', '$($case[2])', no approval, no confirmation, no change" (
                (Test-FakeRun $rr 1 @('[GATE_FAILED]', 'STOP. ', $case[2], 'Manual investigation') @('Approval code accepted', 'Confirmation sentence accepted', 'STOPPED BEFORE THE CHANGE', 'Approval code for', 'Running the one schema-changing command')) -and
                (@($rr.FakeCalls | Where-Object { $_ -match '^dotnet .*ef\s+database' }).Count -eq 0))
        }
    }
    $docCreates = @(ConvertFrom-EfCreateIndexes (($manualCode) -join "`n"))
    Add-Result 'E' 'the CREATE INDEX lines of the manual block in SCHEMA_STEP.md equal the EF restoration script, line for line' (($docCreates.Count -eq 5) -and (((Sort-StepOrdinal $docCreates) -join "`n") -ceq ((Sort-StepOrdinal @(ConvertFrom-EfCreateIndexes $up)) -join "`n")))

    # ---- E6a2. only the pinned original snapshot is accepted (valid but different, or hand-edited, snapshots are refused offline) ----------------------
    $otherSnapRoot = Join-Path $tempRoot 'snap-not-original'
    New-Item -ItemType Directory -Path $otherSnapRoot | Out-Null
    $otherState = ConvertTo-State (Edit-Lines $withLines 'target|*' 'CP1_CI_AS' 'CP1_CS_AS')
    [IO.File]::WriteAllText((Join-Path $otherSnapRoot 'RequestManagement_Perf.pre-step2.txt'), (Format-StepSnapshot $otherState '2026-10-27T00:00:00' 'localhost,1433'))
    $handEdited = (Format-StepSnapshot $withState '2026-10-27T00:00:00' 'localhost,1433').Replace('collation=SQL_Latin1_General_CP1_CI_AS', 'collation=SQL_Latin1_General_CP1_CS_AS')
    $editedRoot = Join-Path $tempRoot 'snap-edited'
    New-Item -ItemType Directory -Path $editedRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $editedRoot 'RequestManagement_Perf.pre-step2.txt'), $handEdited)
    foreach ($case in @(@('a valid snapshot of a different state', $otherSnapRoot), @('the original with one fact edited and its header left alone', $editedRoot))) {
        foreach ($act in @('Check', 'RemoveIndexes', 'RestoreIndexes')) {
            $r = Invoke-Script $setIndexState @('-Action', $act, '-SnapshotRoot', $case[1]) $goodCs
            Add-Result 'E' "$act refuses $($case[0]): SNAPSHOT_NOT_ORIGINAL before any process" (($r.Exit -eq 1) -and $r.Output.Contains('[SNAPSHOT_NOT_ORIGINAL]') -and ($r.Started.Count -eq 0) -and -not $r.Output.Contains($fake))
        }
    }

    # The pin is on the compared facts, as a full 64-character hash, compared case-sensitively and in full. A file is not accepted for
    # "looking the same": a duplicated, added, removed or changed fact changes the hash or fails validity.
    Add-Result 'E' 'pin: the constant is a full 64-character upper-case SHA-256 and the entry script compares all of it case-sensitively (-cne), with no Substring in the comparison' (
        ($script:StepOriginalSnapshotFactsSha256 -cmatch '^[0-9A-F]{64}$') -and $entryText.Contains('if ($snapshotSha -cne $script:StepOriginalSnapshotFactsSha256)') -and ((Get-StepFactsSha256 $withState) -cmatch '^[0-9A-F]{64}$'))
    $mutantBase = (Format-StepSnapshot $withState '2026-10-27T00:00:00' 'localhost,1433') -split "`n"
    $factLine = 'dataset|rows=100000|checksum=-1953119262'
    $uncountedLine = 'by_priority|1|40005'
    $mutants = [ordered]@{
        'a duplicated fact line'         = @{ Lines = @($mutantBase | ForEach-Object { $_; if ($_ -ceq $uncountedLine) { $_ } }); Code = 'SNAPSHOT_NOT_ORIGINAL' }
        'an added fact line'             = @{ Lines = @($mutantBase + 'constraint|Requests|CK_Requests_Extra'); Code = 'SNAPSHOT_INVALID' }
        'a removed fact line'            = @{ Lines = @($mutantBase | Where-Object { $_ -cne 'by_status|2|29844' }); Code = 'SNAPSHOT_INVALID' }
        'an index option changed'        = @{ Lines = @($mutantBase | ForEach-Object { if ($_ -like 'index|Requests|IX_Requests_Priority_Status|*') { $_.Replace('fill=0', 'fill=90') } else { $_ } }); Code = 'SNAPSHOT_INVALID' }
        'the ProductVersion changed'     = @{ Lines = @($mutantBase | ForEach-Object { if ($_ -like 'migration|20261020183100_AddQueryIndexes|*') { $_.Replace('10.0.13', '10.0.14') } else { $_ } }); Code = 'SNAPSHOT_NOT_ORIGINAL' }
        'the collation changed'          = @{ Lines = @($mutantBase | ForEach-Object { $_.Replace('CP1_CI_AS', 'CP1_CS_AS') }); Code = 'SNAPSHOT_NOT_ORIGINAL' }
        'a leading space on a fact line' = @{ Lines = @($mutantBase | ForEach-Object { if ($_ -ceq $factLine) { " $_" } else { $_ } }); Code = 'SNAPSHOT_INVALID' }
    }
    foreach ($name in $mutants.Keys) {
        $root = Join-Path $tempRoot ('snap-mutant-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'RequestManagement_Perf.pre-step2.txt'), ($mutants[$name].Lines -join "`n"))
        $r = Invoke-Script $setIndexState @('-Action', 'Check', '-SnapshotRoot', $root) $goodCs
        Add-Result 'E' "pin: a snapshot with $name is refused with $($mutants[$name].Code) before any process, although it is almost the original" (($r.Exit -eq 1) -and $r.Output.Contains("[$($mutants[$name].Code)]") -and ($r.Started.Count -eq 0))
    }
    # What the pin does not look at, on purpose: the header, the timestamp, the informational pages lines and the order of the fact lines
    # are used by no gate and by no approval code, so a file that differs only there describes the identical recorded state.
    $reordered = @($mutantBase | Where-Object { $_ -match '^#' }) + @($mutantBase | Where-Object { $_ -match '^(index|constraint|migration)\|' } | Sort-Object -Descending) + @($mutantBase | Where-Object { $_ -match '^(bounds|by_|dataset|fk|target)' }) + @('pages|Requests|PK_Requests|9999', 'sessions|0')
    $sameFactsRoot = Join-Path $tempRoot 'snap-same-facts'
    New-Item -ItemType Directory -Path $sameFactsRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $sameFactsRoot 'RequestManagement_Perf.pre-step2.txt'), (($reordered -join "`n").Replace('# Taken 2026-10-27T00:00:00', '# Taken 2030-01-01T00:00:00')))
    $rr = Invoke-FakeRun @('-Action', 'Check', '-SnapshotRoot', $sameFactsRoot) (New-FakeWorld)
    Add-Result 'E' 'pin (documented): the same facts with another timestamp, other pages numbers and another line order are the same recorded state and are accepted' (Test-FakeRun $rr 0 @('CHECK OK'))

    # ---- E6b. the password and the sqlcmd environment: names of the SQLCMD* variables each fake sqlcmd call saw (never their values) -------------------
    [Environment]::SetEnvironmentVariable('SQLCMDINI', 'C:\evil\startup.sql', 'Process')
    [Environment]::SetEnvironmentVariable('SQLCMDUSER', 'someone-else', 'Process')
    [Environment]::SetEnvironmentVariable('SQLCMDSERVER', 'sql.example.com', 'Process')
    try { $envRun = Invoke-FakeRun @('-Action', 'Check', '-SnapshotRoot', $snapRoot) (New-FakeWorld) }
    finally { foreach ($n in @('SQLCMDINI', 'SQLCMDUSER', 'SQLCMDSERVER')) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') } }
    $sqlcmdCalls = @($envRun.FakeCalls | Where-Object { $_ -match '^sqlcmd ' })
    Add-Result 'E' 'sqlcmd calls (guard queries and state query): 3 calls, each with SQLCMDPASSWORD' ((Test-FakeRun $envRun 0 @('CHECK OK')) -and ($sqlcmdCalls.Count -eq 3) -and (@($sqlcmdCalls | Where-Object { $_ -match '\[env:[^\]]*SQLCMDPASSWORD' }).Count -eq 3)) ($sqlcmdCalls -join ' ; ')
    Add-Result 'E' 'sqlcmd calls: SQLCMDINI, SQLCMDUSER and SQLCMDSERVER of the parent never reach sqlcmd (guard and shared function)' (@($sqlcmdCalls | Where-Object { $_ -match 'SQLCMD(INI|USER|SERVER)' }).Count -eq 0) ($sqlcmdCalls -join ' ; ')
    Add-Result 'E' 'sqlcmd calls: the password is in no argument, no log line and no output of any fake run (the test password is $fake)' (
        (@(Get-ChildItem -LiteralPath $tempRoot -Recurse -Filter 'fake.log' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($fake) }).Count -eq 0) -and -not $envRun.Output.Contains($fake))

    # ---- E7. over all the runs above ----------------------------------------------------------------------------------------------------------------------
    Add-Result 'E' "over $($fakeCounter.N) fake worlds and all the runs above, no run ever started `dotnet ef database update` (fake log and script log)" ($updateCalls.Count -eq 0) ($updateCalls -join ' ; ')
    Add-Result 'E' 'none of these runs wrote into docs/perf/results or created docs/perf/snapshots' (((Get-TreeSnapshot (Join-Path $perfDir 'results')) -ceq $resultsTreeBefore) -and ((Test-Path -LiteralPath (Join-Path $perfDir 'snapshots')) -eq $defaultSnapshotsExisted))

    # ============================================================================================================
    # B. the scripts as child processes
    # ============================================================================================================
    foreach ($tool in @(@{ Name = 'run-sql'; Path = $runSql }, @{ Name = 'measure-api'; Path = $measureApi })) {
        $name = $tool.Name
        $path = $tool.Path
        $isSql = ($name -eq 'run-sql')
        $emptyRoot = Join-Path $tempRoot "$name-empty"
        $resultsRoot = Join-Path $tempRoot "$name-results"

        # B1. refusals before anything is started: (case, arguments, connection string, expected code)
        $stopCases = @(
            @('phase missing', @(), $goodCs, 'PHASE_MISSING'),
            @('phase missing (dry run)', @('-DryRun'), $goodCs, 'PHASE_MISSING'),
            @('environment variable not set', @('-Phase', 'before'), $null, 'ENV_MISSING'),
            @('environment variable not set (dry run)', @('-Phase', 'before', '-DryRun'), $null, 'ENV_MISSING'),
            @('dev database', @('-Phase', 'before'), (Cs 'localhost,1433' 'RequestManagement'), 'TARGET_MISMATCH'),
            @('dev database (dry run)', @('-Phase', 'before', '-DryRun'), (Cs 'localhost,1433' 'RequestManagement'), 'TARGET_MISMATCH'),
            @('SeedCheck database', @('-Phase', 'before'), (Cs 'localhost,1433' 'RequestManagement_SeedCheck'), 'TARGET_MISMATCH'),
            @('remote server', @('-Phase', 'before'), (Cs 'sql.example.com,1433' 'RequestManagement_Perf'), 'TARGET_MISMATCH'),
            @('wrong port', @('-Phase', 'before'), (Cs 'localhost,1434' 'RequestManagement_Perf'), 'TARGET_MISMATCH'),
            @('Perf name in wrong case', @('-Phase', 'after', '-DryRun'), (Cs 'localhost,1433' 'requestmanagement_perf'), 'TARGET_MISMATCH'),
            @('subset without -ResultsRoot', @('-Phase', 'before', '-Scenario', 'B2'), $goodCs, 'PARTIAL_NEEDS_RESULTSROOT'),
            @('subset with -ResultsRoot equal to the default', @('-Phase', 'before', '-Scenario', 'B2', '-ResultsRoot', (Join-Path $perfDir 'results')), $goodCs, 'PARTIAL_NEEDS_RESULTSROOT'),
            @('subset with the default folder in another spelling', @('-Phase', 'before', '-Scenario', 'B2', '-ResultsRoot', (Join-Path $perfDir 'results\..\results')), $goodCs, 'PARTIAL_NEEDS_RESULTSROOT'),
            @('subset with the default folder in upper case', @('-Phase', 'before', '-Scenario', 'B2', '-ResultsRoot', ((Join-Path $perfDir 'results').ToUpperInvariant())), $goodCs, 'PARTIAL_NEEDS_RESULTSROOT'),
            @('results root inside the official folder', @('-Phase', 'before', '-ResultsRoot', (Join-Path $perfDir 'results\sub'), '-DryRun'), $goodCs, 'RESULTS_ROOT_INSIDE_OFFICIAL'),
            @('results root on a UNC path', @('-Phase', 'before', '-ResultsRoot', '\\server\share\x', '-DryRun'), $goodCs, 'RESULTS_ROOT_INVALID'),
            @('results root with a wildcard', @('-Phase', 'before', '-ResultsRoot', (Join-Path $tempRoot 'a*b'), '-DryRun'), $goodCs, 'RESULTS_ROOT_INVALID')
        )
        foreach ($case in $stopCases) {
            $r = Invoke-Script $path $case[1] $case[2]
            $ok = ($r.Exit -eq 1) -and $r.Output.Contains("[$($case[3])]") -and -not $r.Output.Contains($fake) -and ($r.Started.Count -eq 0) -and -not $r.Output.Contains('DRY RUN OK')
            Add-Result 'B' "$name stops with $($case[3]): $($case[0])" $ok "exit $($r.Exit); started $($r.Started.Count)"
        }

        # B2. invalid parameter values are rejected by parameter validation (non-zero exit, nothing started, no plan printed)
        foreach ($bad in @(@('invalid phase', @('-Phase', 'during')), @('invalid scenario', @('-Phase', 'before', '-Scenario', 'B9', '-ResultsRoot', $emptyRoot)), @('unknown parameter', @('-Phase', 'before', '-Frobnicate')))) {
            $r = Invoke-Script $path $bad[1] $goodCs
            Add-Result 'B' "$name rejects $($bad[0])" (($r.Exit -ne 0) -and ($r.Started.Count -eq 0) -and -not $r.Output.Contains('DRY RUN OK') -and -not $r.Output.Contains($fake))
        }
        if (-not $isSql) {
            foreach ($port in @('80', 'abc')) {
                $r = Invoke-Script $path @('-Phase', 'before', '-DryRun', '-Port', $port) $goodCs
                Add-Result 'B' "measure-api rejects -Port $port" (($r.Exit -ne 0) -and ($r.Started.Count -eq 0) -and -not $r.Output.Contains('DRY RUN OK'))
            }
        }

        # B3. existing results are never replaced without -Overwrite (real run and dry run), and nothing is created or changed
        $existingRel = if ($isSql) { 'before/indexes.txt' } else { 'before/api.csv' }
        $existingFile = Join-Path $resultsRoot ($existingRel -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path $existingFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $existingFile -Value 'precious result' -Encoding ASCII
        $snapshot = Get-TreeSnapshot $resultsRoot
        foreach ($mode in @(@('real run', @()), @('dry run', @('-DryRun')))) {
            $r = Invoke-Script $path (@('-Phase', 'before', '-ResultsRoot', $resultsRoot) + $mode[1]) $goodCs
            $ok = ($r.Exit -eq 1) -and $r.Output.Contains('[RESULTS_EXIST]') -and ($r.Started.Count -eq 0) -and ((Get-TreeSnapshot $resultsRoot) -ceq $snapshot) -and -not $r.Output.Contains($fake)
            Add-Result 'B' "$name refuses to replace existing results ($($mode[0]))" $ok "exit $($r.Exit); started $($r.Started.Count)"
        }
        $r = Invoke-Script $path @('-Phase', 'after', '-ResultsRoot', $resultsRoot, '-DryRun') $goodCs
        Add-Result 'B' "$name dry run for the other phase is not blocked by the results of 'before'" (($r.Exit -eq 0) -and $r.Output.Contains('DRY RUN OK'))
        $r = Invoke-Script $path @('-Phase', 'before', '-ResultsRoot', $resultsRoot, '-DryRun', '-Overwrite') $goodCs
        Add-Result 'B' "$name dry run with -Overwrite plans the replacement and still changes nothing" (($r.Exit -eq 0) -and $r.Output.Contains('DRY RUN OK') -and $r.Output.Contains('-Overwrite') -and ((Get-TreeSnapshot $resultsRoot) -ceq $snapshot) -and ((Get-Content -LiteralPath $existingFile -Raw).Trim() -ceq 'precious result'))

        # B4. dry run: succeeds, plans exactly the T-502 names, starts nothing, writes nothing
        foreach ($phase in @('before', 'after')) {
            $before = Get-TreeSnapshot $emptyRoot
            $r = Invoke-Script $path @('-Phase', $phase, '-ResultsRoot', $emptyRoot, '-DryRun') $goodCs
            $planned = @(Get-PlanFiles $r.Output)
            $expected = if ($isSql) { @(Get-ExpectedSqlNames $phase) } else { @(Get-ExpectedApiNames $phase) }
            if ($isSql -and $phase -eq 'before') { $expected = @($expected + 'environment.txt' | Sort-Object) }
            Add-Result 'B' "$name dry run '$phase' exits 0 and announces that nothing was executed" (($r.Exit -eq 0) -and $r.Output.Contains('DRY RUN OK - nothing was executed.'))
            Add-Result 'B' "$name dry run '$phase' plans exactly the T-502 file names" (($planned -join ',') -ceq ($expected -join ',')) ($planned -join ',')
            Add-Result 'B' "$name dry run '$phase' starts no process (T501_CHILD_LOG empty)" ($r.Started.Count -eq 0) ($r.Started -join ' ; ')
            Add-Result 'B' "$name dry run '$phase' writes nothing (the results root is not even created)" ((Get-TreeSnapshot $emptyRoot) -ceq $before -and -not (Test-Path -LiteralPath $emptyRoot))
            Add-Result 'B' "$name dry run '$phase' prints no password and no connection string" (-not $r.Output.Contains($fake) -and -not $r.Output.Contains('Password=') -and -not $r.Output.Contains('User Id'))
            Add-Result 'B' "$name dry run '$phase' reports that the SQL / requests were verified against the approved hashes" ($r.Output -match '(SQL|Request) policy \(checked now, offline\)')
        }
        $r = Invoke-Script $path @('-Phase', 'before', '-ResultsRoot', $emptyRoot, '-DryRun', '-KeepWorkOnFailure') $goodCs
        Add-Result 'B' "$name accepts -KeepWorkOnFailure" (($r.Exit -eq 0) -and ($r.Started.Count -eq 0))

        # B5. dry run with the default results root changes nothing in docs/perf/results
        $defaultBefore = Get-TreeSnapshot (Join-Path $perfDir 'results')
        $r = Invoke-Script $path @('-Phase', 'before', '-DryRun') $goodCs
        Add-Result 'B' "$name dry run on the default results root leaves docs/perf/results untouched" ((($r.Exit -eq 0) -or $r.Output.Contains('[RESULTS_EXIST]')) -and ((Get-TreeSnapshot (Join-Path $perfDir 'results')) -ceq $defaultBefore) -and ($r.Started.Count -eq 0))

        # B6. a subset with its own results root
        $subsetRoot = Join-Path $tempRoot "$name-subset"
        $r = Invoke-Script $path @('-Phase', 'before', '-Scenario', 'B2', '-ResultsRoot', $subsetRoot, '-DryRun') $goodCs
        $planned = @(Get-PlanFiles $r.Output)
        if ($isSql) {
            $expected = @((Get-ExpectedSqlNames 'before' @('B2')) + 'environment.txt' | Sort-Object)
            Add-Result 'B' 'run-sql dry run for B2 only plans only the B2 statements' (($r.Exit -eq 0) -and (($planned -join ',') -ceq ($expected -join ',')))
        }
        else {
            Add-Result 'B' 'measure-api dry run for B2 plans both variants: cache enabled and SummaryCache__Enabled=false' (
                ($r.Exit -eq 0) -and $r.Output.Contains('PLAN API: B2 cache-on cache_enabled=true') -and $r.Output.Contains('PLAN API: B2 cache-off cache_enabled=false') -and
                $r.Output.Contains('SummaryCache__Enabled=false') -and $r.Output.Contains('SummaryCache__Enabled=true') -and -not $r.Output.Contains('PLAN API: B1'))
        }
        Add-Result 'B' "$name dry run for a subset starts nothing and writes nothing" (($r.Started.Count -eq 0) -and -not (Test-Path -LiteralPath $subsetRoot))
    }

    # B7. measure-api dry run: the calls are the section 5.1 requests, B2 with and without the cache
    $r = Invoke-Script $measureApi @('-Phase', 'before', '-DryRun') $goodCs
    $apiLines = @($r.Output -split "`r?`n" | Where-Object { $_ -match '^PLAN API:' })
    Add-Result 'B' 'measure-api dry run plans 8 calls: B1a-B1f (default) and B2 cache-on / cache-off' (($apiLines.Count -eq 8) -and $r.Output.Contains("$($script:ApiWarmupCalls) warm-up + $($script:ApiMeasuredCalls) measured"))
    Add-Result 'B' 'measure-api dry run uses the captured B1a and B1c requests' ($r.Output.Contains('GET /api/requests?status=InProgress&priority=High&createdFrom=2026-07-03T00:00:00Z&createdTo=2026-10-01T00:00:00Z&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20') -and $r.Output.Contains('GET /api/requests?search=payroll&status=New&page=1&pageSize=20'))
    Add-Result 'B' 'measure-api dry run uses 10 warm-up and 100 measured calls (section 5.2, step 4)' (($script:ApiWarmupCalls -eq 10) -and ($script:ApiMeasuredCalls -eq 100) -and ($script:SqlWarmupRuns -eq 1) -and ($script:SqlMeasuredRuns -eq 5))

    # ============================================================================================================
    # C. static checks of the sources
    # ============================================================================================================
    $sources = @{ 'run-sql.ps1' = $runSql; 'measure-api.ps1' = $measureApi; 'perf-common.ps1' = $commonPath; 'guard-perf-target.ps1' = $guardPath }
    foreach ($key in $sources.Keys) {
        # Code only: help blocks and comment lines are removed first.
        $raw = Get-Content -LiteralPath $sources[$key] -Raw
        $code = (([regex]::Replace($raw, '(?s)<#.*?#>', '') -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        Add-Result 'C' "$key has no migration, Seeder or reset call in its code" `
            (($code -notmatch '(?i)database\s+update') -and ($code -notmatch '(?i)dotnet(\.exe)?''?\s*,?\s*''?ef\b') -and ($code -notmatch '--reset|--create-new|Seeder\.dll|sp_addextendedproperty'))
        if ($key -in @('run-sql.ps1', 'measure-api.ps1')) {
            # perf-common.ps1 holds the pattern list of the grammar itself; the SQL it builds is tested in group A.
            Add-Result 'C' "$key has no schema- or data-changing SQL keyword in its code" ($code -cnotmatch '\b(DROP|DELETE|TRUNCATE|ALTER|INSERT|UPDATE|MERGE|DBCC)\b')
            Add-Result 'C' "$key never passes SQL text to Invoke-PerfSqlcmd (it names a kind and a registered statement)" ($code -notmatch 'Invoke-PerfSqlcmd[^\r\n]*-Sql\b')
            Add-Result 'C' "$key finds its tools with Resolve-PerfTool, not Get-Command or a bare name" (($code -notmatch 'Get-Command\s+\$tool') -and ($code -notmatch "Start-Process -FilePath '"))
            Add-Result 'C' "$key removes its temporary folder after an unexpected error (trap) and has -KeepWorkOnFailure" (($code -match '(?m)^trap \{ Invoke-PerfFailureCleanup; break \}') -and ($code -match '\[switch\]\$KeepWorkOnFailure'))
        }
    }
    foreach ($key in @('run-sql.ps1', 'measure-api.ps1')) {
        $text = Get-Content -LiteralPath $sources[$key] -Raw
        $firstSql = $text.IndexOf('Invoke-PerfSqlcmd -Builder')
        $guard = $text.IndexOf('Invoke-ServerGuard $builder')
        Add-Result 'C' "$key runs the server guard before its first SQL" (($guard -gt 0) -and ($firstSql -gt $guard))
        $dry = $text.IndexOf('# ---- 3. dry run')
        $dryEnd = $text.IndexOf('# ---- 4. real run')
        $beforeDry = $text.Substring(0, $dryEnd)
        Add-Result 'C' "$key starts no process, sqlcmd, git or API before its dry-run exit" (($dry -gt 0) -and ($dryEnd -gt $dry) -and ($beforeDry -notmatch 'Invoke-ChildProcess|Invoke-PerfSqlcmd|Invoke-ServerGuard|Start-Process|Get-GitText|Assert-SqlFilesFresh|Start-ApiInstance|New-PerfWorkDir|HttpClient|Resolve-PerfTool'))
        Add-Result 'C' "$key checks the SQL policy and the target before the dry-run exit" (($text.IndexOf('Register-PerfStatements $sqlFiles') -gt 0) -and ($text.IndexOf('Register-PerfStatements $sqlFiles') -lt $dry) -and ($text.IndexOf('$builder = Get-PerfTarget') -gt 0) -and ($text.IndexOf('$builder = Get-PerfTarget') -lt $dry))
        Add-Result 'C' "$key never prints the connection string or the password" ($text -notmatch 'Write-Host[^\r\n]*\$connectionString' -and $text -notmatch 'Write-Host[^\r\n]*\.Password')
    }
    $commonText = Get-Content -LiteralPath $commonPath -Raw
    Add-Result 'C' 'Invoke-PerfSqlcmd checks the guard approval before it builds any SQL' (($commonText.IndexOf('Assert-GuardApproved $Builder') -gt 0) -and ($commonText.IndexOf('Assert-GuardApproved $Builder') -lt $commonText.IndexOf('$sql = Get-ApprovedSql')))
    Add-Result 'C' 'Invoke-ChildProcess checks the approval for sqlcmd and dotnet before it resolves or starts the tool' (($commonText.IndexOf('if ($script:PerfGuardedTools -contains $leaf) { Assert-GuardApproved }') -gt 0) -and ($commonText.IndexOf('if ($script:PerfGuardedTools -contains $leaf) { Assert-GuardApproved }') -lt $commonText.IndexOf('$path = Resolve-PerfTool $FileName')))
    Add-Result 'C' 'Invoke-ServerGuard clears the approval first and sets it only after the guard confirmed this server and database' (
        ($commonText -match '(?s)function Invoke-ServerGuard.*?\$script:PerfGuardApproval = \$null.*?GUARD: OK.*?\$script:PerfGuardApproval = \[pscustomobject\]'))
    $apiText = Get-Content -LiteralPath $measureApi -Raw
    Add-Result 'C' 'Start-ApiInstance asserts the guard approval as its first statement' ($apiText -match '(?s)function Start-ApiInstance\([^)]*\) \{\s*(?:#[^\r\n]*\s*)*Assert-GuardApproved \$builder')
    Add-Result 'C' 'measure-api sends GET requests only, never follows a redirect, and sends the checked connection string' (
        ($apiText -match 'GetAsync') -and ($apiText -notmatch '(?i)PostAsync|PutAsync|DeleteAsync|PatchAsync|SendAsync|-Method\s+(Post|Put|Delete|Patch)') -and
        $apiText.Contains('$handler.AllowAutoRedirect = $false') -and $apiText.Contains('$checkedConnectionString = $builder.ConnectionString') -and $apiText.Contains("`$values['ConnectionStrings__RequestManagement'] = `$checkedConnectionString"))
    Add-Result 'C' 'measure-api verifies the port, its owner and the loopback address' ($apiText.Contains('Test-PerfPortFree $Port') -and $apiText.Contains('Test-ListenerOwnership $listeners $process.Id') -and $apiText.Contains('Test-PerfLoopbackUrl'))
}
finally {
    [Environment]::SetEnvironmentVariable('T501_CHILD_LOG', $savedLog, 'Process')
    if ($null -eq $savedEnv) { Remove-Item "Env:$envName" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($envName, $savedEnv, 'Process') }
    # Links first, so that deleting the folder can never follow one out of it.
    Remove-LinksIn $tempRoot
    if ($tempRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $tempRoot -Leaf) -like 't501-test-*') {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results | Format-Table Group, Pass, Case -AutoSize -Wrap | Out-String -Width 240 | Write-Host
$failed = @($results | Where-Object { -not $_.Pass })
foreach ($f in $failed) { Write-Host "FAILED [$($f.Group)] $($f.Case) $($f.Detail)" -ForegroundColor Red }
Write-Host ("{0} of {1} perf-script cases behaved as expected." -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
