<#
.SYNOPSIS
    T-501, step 2 of work plan section 5.2: the pure, offline-testable parts of set-index-state.ps1 (dot-sourced after
    perf-common.ps1; it defines functions and constants only and starts nothing).

.DESCRIPTION
    - the expected state of RequestManagement_Perf, with and without the five AddQueryIndexes indexes, and the gates that
      compare an observed state with it (Get-StepGateFailures);
    - the snapshot file: how a state is rendered, read back and compared;
    - the approval: a code that binds an explicit "yes" to one action, one database and one verified state
      (Get-StepApprovalCode), the grant that checks it (Grant-SchemaChangeApproval), and the ONLY function in these scripts
      that can run `dotnet ef database update` (Invoke-EfDatabaseUpdate), which refuses without a matching, unused grant;
    - the SQL that Entity Framework must produce for the removal and the restoration, as text to compare with.

    What the approval can and cannot do: code cannot know whether a human said yes. The grant makes the schema change
    unreachable unless the caller supplies the exact code of the state that was just verified, the exact database name and the
    -Execute switch; the code changes with every difference in the state, so an approval given for one state is void for
    another. That the code was given by a person who decided is a procedural requirement of the project, not something this
    file can prove.
#>

# ---- what the database must look like ----------------------------------------------------------------------------------------

$script:StepExpectedRows = '100000'
$script:StepExpectedChecksum = '-1953119262'   # results/dataset.txt, DatabaseSeeder.GetReportAsync formula, verified in T-104
$script:StepExpectedByStatus = @('by_status|1|19831', 'by_status|2|29844', 'by_status|3|14982', 'by_status|4|35343')
$script:StepExpectedByPriority = @('by_priority|1|40005', 'by_priority|2|45166', 'by_priority|3|14829')
$script:StepExpectedBounds = 'bounds|min_id=1|max_id=100000|min_created=2024-10-01 00:12:49.685|max_created=2026-09-30 23:45:30.586|history_rows=0'
$script:StepMigrationInitial = '20261020183000_InitialCreate'
$script:StepMigrationIndexes = '20261020183100_AddQueryIndexes'
$script:StepExpectedConstraints = @(
    'constraint|Requests|CK_Requests_Priority', 'constraint|Requests|CK_Requests_Status', 'constraint|Requests|CK_Requests_UpdatedAt_NotBeforeCreatedAt',
    'constraint|RequestStatusHistory|CK_RequestStatusHistory_NewStatus', 'constraint|RequestStatusHistory|CK_RequestStatusHistory_PreviousStatus',
    'constraint|RequestStatusHistory|CK_RequestStatusHistory_StatusChanged')
$script:StepExpectedForeignKey = 'fk|RequestStatusHistory|FK_RequestStatusHistory_Requests_RequestId|delete=NO_ACTION'
$script:StepRequiredOtherIndexes = @('index|RequestStatusHistory|PK_RequestStatusHistory|', 'index|RequestStatusHistory|IX_RequestStatusHistory_RequestId_ChangedAt|')

# index|table|name|type|unique|pk|fill|padded|ignoredup|rowlocks|pagelocks|filter|seqkey|disabled|keys|include|compression
function Format-StepIndexLine([string]$Table, [string]$Name, [string]$Type, [int]$Unique, [int]$Pk, [string]$Keys, [string]$Include) {
    "index|$Table|$Name|$Type|unique=$Unique|pk=$Pk|fill=0|padded=0|ignoredup=0|rowlocks=1|pagelocks=1|filter=0|seqkey=0|disabled=0|keys=$Keys|include=$Include|compression=NONE"
}

# Name -> the exact line the five AddQueryIndexes indexes must have when they exist (verified against the live database on 2026-10-26).
function Get-StepQueryIndexLines {
    [ordered]@{
        'IX_Requests_AssignedTo_Status_CreatedAt' = (Format-StepIndexLine 'Requests' 'IX_Requests_AssignedTo_Status_CreatedAt' 'NONCLUSTERED' 0 0 'AssignedTo ASC, Status ASC, CreatedAt DESC' '')
        'IX_Requests_CreatedAt_Id'                = (Format-StepIndexLine 'Requests' 'IX_Requests_CreatedAt_Id' 'NONCLUSTERED' 0 0 'CreatedAt DESC, Id DESC' '')
        'IX_Requests_OrganizationName_CreatedAt'  = (Format-StepIndexLine 'Requests' 'IX_Requests_OrganizationName_CreatedAt' 'NONCLUSTERED' 0 0 'OrganizationName ASC, CreatedAt DESC' '')
        'IX_Requests_Priority_Status'             = (Format-StepIndexLine 'Requests' 'IX_Requests_Priority_Status' 'NONCLUSTERED' 0 0 'Priority ASC, Status ASC' '')
        'IX_Requests_Status_CreatedAt'            = (Format-StepIndexLine 'Requests' 'IX_Requests_Status_CreatedAt' 'NONCLUSTERED' 0 0 'Status ASC, CreatedAt DESC' 'Priority')
    }
}
function Get-StepPrimaryKeyLine { Format-StepIndexLine 'Requests' 'PK_Requests' 'CLUSTERED' 1 1 'Id ASC' '' }

# ---- parsing and comparing states ----------------------------------------------------------------------------------------------

function Sort-StepOrdinal([string[]]$Values) {
    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    , $copy
}

# The output of the SchemaState query. Facts are the stable lines (compared); pages and sessions are informational.
function ConvertFrom-SchemaState([string]$Text) {
    $facts = New-Object System.Collections.Generic.List[string]
    $pages = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    $sessions = $null
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.TrimEnd()
        if ($l.Trim() -eq '') { continue }
        if ($l -match '^sessions\|(\d+)$') { $sessions = [int]$matches[1]; continue }
        if ($l -match '^pages\|') { $pages.Add($l); continue }
        if ($l -match '^(target|dataset|by_status|by_priority|bounds|migration|index|constraint|fk)\|') { $facts.Add($l); continue }
        $unexpected.Add($l)
    }
    [pscustomobject]@{
        Facts = @(Sort-StepOrdinal @($facts.ToArray()))[0]
        Pages = @($pages.ToArray())
        Sessions = $sessions
        Unexpected = @($unexpected.ToArray())
    }
}

function Get-StepFactMap([string]$Line) {
    $map = @{}
    foreach ($token in ($Line -split '\|')) {
        $eq = $token.IndexOf('=')
        if ($eq -gt 0) { $map[$token.Substring(0, $eq)] = $token.Substring($eq + 1) }
    }
    $map
}

function Get-StepSetDifference([string[]]$A, [string[]]$B) {
    $inB = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($x in @($B)) { [void]$inB.Add($x) }
    @(@($A) | Where-Object { -not $inB.Contains($_) })
}

# The facts a database must have in the given kind of state, derived from a snapshot taken WITH the indexes.
function Get-StepFactsForKind($Snapshot, [string]$Kind) {
    if ($Kind -ceq 'WithIndexes') { return @($Snapshot.Facts) }
    $names = @((Get-StepQueryIndexLines).Keys)
    @($Snapshot.Facts | Where-Object {
        $line = $_
        -not ($line -like "migration|$($script:StepMigrationIndexes)|*") -and
        -not (@($names | Where-Object { $line -like "index|Requests|$_|*" }).Count -gt 0)
    })
}

# Every reason why the observed state is not the expected one; an empty list means every gate passed. Kind: WithIndexes (before
# step 2, and after a restoration) or WithoutIndexes (after the removal). A snapshot adds the comparison with the recorded state.
function Get-StepGateFailures($Observed, [string]$Kind, $Snapshot = $null) {
    $failures = New-Object System.Collections.Generic.List[string]
    if ($Kind -cne 'WithIndexes' -and $Kind -cne 'WithoutIndexes') { $failures.Add("unknown state kind '$Kind'"); return @($failures.ToArray()) }
    if (@($Observed.Unexpected).Count -gt 0) { $failures.Add("the state query returned unexpected output ($(@($Observed.Unexpected).Count) line(s)); first: '$(@($Observed.Unexpected)[0])'") }
    $facts = @($Observed.Facts)
    if ($facts.Count -eq 0) { $failures.Add('the state query returned no facts'); return @($failures.ToArray()) }

    $target = @($facts | Where-Object { $_ -like 'target|*' })
    if ($target.Count -ne 1) { $failures.Add("expected one target line, found $($target.Count)") }
    else {
        $m = Get-StepFactMap $target[0]
        if ($m['db'] -cne 'RequestManagement_Perf') { $failures.Add("database is '$($m['db'])', expected exactly 'RequestManagement_Perf'") }
        if ($m['marker'] -cne '1') { $failures.Add('the T501_PERF_DB marker is missing or has another value') }
        if ($m['state'] -cne 'ONLINE') { $failures.Add("database state is '$($m['state'])', expected ONLINE") }
        if ($m['readonly'] -cne '0') { $failures.Add('the database is read-only') }
    }

    $dataset = @($facts | Where-Object { $_ -like 'dataset|*' })
    if ($dataset.Count -ne 1) { $failures.Add("expected one dataset line, found $($dataset.Count)") }
    else {
        $m = Get-StepFactMap $dataset[0]
        if ($m['rows'] -cne $script:StepExpectedRows) { $failures.Add("Requests has $($m['rows']) rows, expected $($script:StepExpectedRows)") }
        if ($m['checksum'] -cne $script:StepExpectedChecksum) { $failures.Add("the dataset checksum is $($m['checksum']), expected $($script:StepExpectedChecksum)") }
    }
    if ((@(Get-StepSetDifference @($facts | Where-Object { $_ -like 'by_status|*' }) $script:StepExpectedByStatus)).Count -gt 0 -or (@(Get-StepSetDifference $script:StepExpectedByStatus @($facts | Where-Object { $_ -like 'by_status|*' }))).Count -gt 0) { $failures.Add('the distribution by status differs from results/dataset.txt') }
    if ((@(Get-StepSetDifference @($facts | Where-Object { $_ -like 'by_priority|*' }) $script:StepExpectedByPriority)).Count -gt 0 -or (@(Get-StepSetDifference $script:StepExpectedByPriority @($facts | Where-Object { $_ -like 'by_priority|*' }))).Count -gt 0) { $failures.Add('the distribution by priority differs from results/dataset.txt') }
    $bounds = @($facts | Where-Object { $_ -like 'bounds|*' })
    if ($bounds.Count -ne 1 -or $bounds[0] -cne $script:StepExpectedBounds) { $failures.Add('the id and date bounds, or the history row count, differ from results/dataset.txt') }

    $migrations = @($facts | Where-Object { $_ -like 'migration|*' } | ForEach-Object { ($_ -split '\|')[1] })
    $expectedMigrations = if ($Kind -ceq 'WithIndexes') { @($script:StepMigrationInitial, $script:StepMigrationIndexes) } else { @($script:StepMigrationInitial) }
    if (($migrations -join ',') -cne ($expectedMigrations -join ',')) { $failures.Add("migration history is [$($migrations -join ', ')], expected [$($expectedMigrations -join ', ')]") }

    $indexLines = @($facts | Where-Object { $_ -like 'index|*' })
    $requestsIndexes = @($indexLines | Where-Object { $_ -like 'index|Requests|*' })
    $expectedRequests = New-Object System.Collections.Generic.List[string]
    $expectedRequests.Add((Get-StepPrimaryKeyLine))
    if ($Kind -ceq 'WithIndexes') { foreach ($line in (Get-StepQueryIndexLines).Values) { $expectedRequests.Add($line) } }
    $missing = @(Get-StepSetDifference @($expectedRequests.ToArray()) $requestsIndexes)
    $extra = @(Get-StepSetDifference $requestsIndexes @($expectedRequests.ToArray()))
    if ($missing.Count -gt 0) { $failures.Add("Requests is missing or has altered index(es): $(@($missing | ForEach-Object { ($_ -split '\|')[2] }) -join ', ')") }
    if ($extra.Count -gt 0) { $failures.Add("Requests has unexpected or altered index(es): $(@($extra | ForEach-Object { ($_ -split '\|')[2] }) -join ', ')") }
    foreach ($prefix in $script:StepRequiredOtherIndexes) {
        if (@($indexLines | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) }).Count -ne 1) { $failures.Add("missing index '$(($prefix -split '\|')[2])' of RequestStatusHistory") }
    }

    $constraints = @($facts | Where-Object { $_ -like 'constraint|*' })
    if ((@(Get-StepSetDifference $constraints $script:StepExpectedConstraints)).Count -gt 0 -or (@(Get-StepSetDifference $script:StepExpectedConstraints $constraints)).Count -gt 0) { $failures.Add('the CHECK constraints are not the six expected ones') }
    $fks = @($facts | Where-Object { $_ -like 'fk|*' })
    if ($fks.Count -ne 1 -or $fks[0] -cne $script:StepExpectedForeignKey) { $failures.Add('the foreign key is not the one expected') }

    if ($null -eq $Observed.Sessions) { $failures.Add('the number of other sessions on the database is unknown') }
    elseif ($Observed.Sessions -ne 0) { $failures.Add("$($Observed.Sessions) other session(s) are connected to the database") }

    if ($null -ne $Snapshot) {
        $expectedFacts = @(Get-StepFactsForKind $Snapshot $Kind)
        $onlyExpected = @(Get-StepSetDifference $expectedFacts $facts)
        $onlyLive = @(Get-StepSetDifference $facts $expectedFacts)
        if ($onlyExpected.Count -gt 0 -or $onlyLive.Count -gt 0) {
            $failures.Add("the state differs from the snapshot (recorded but not present: $($onlyExpected.Count); present but not recorded: $($onlyLive.Count)); first difference: '$(@($onlyExpected + $onlyLive)[0])'")
        }
    }
    @($failures.ToArray())
}

# ---- the snapshot file ------------------------------------------------------------------------------------------------------------

function Get-StepFactsSha256($Observed) { Get-Sha256Hex (@($Observed.Facts) -join "`n") }

function Format-StepSnapshot($Observed, [string]$TakenAt, [string]$Server) {
    $header = @(
        '# T-501 snapshot of RequestManagement_Perf before step 2 (removal of the five AddQueryIndexes indexes).',
        "# Taken $TakenAt by set-index-state.ps1 -Action Snapshot; SELECT statements only. Server: $Server (Docker container request-management-sql).",
        '# This is NOT a performance result. It holds no credentials and no connection string.',
        '# State: WithIndexes (every gate of set-index-state.ps1 passed when it was taken).',
        "# Facts sha256 (the compared lines only): $(Get-StepFactsSha256 $Observed)"
    )
    (($header + @($Observed.Facts) + @($Observed.Pages) + @("sessions|$($Observed.Sessions)")) -join "`n") + "`n"
}

function Read-StepSnapshot([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    ConvertFrom-SchemaState (($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
}

# ---- the approval -----------------------------------------------------------------------------------------------------------------------

# Binds one action, one database and one verified state (and the snapshot it was verified against) to a short code.
function Get-StepApprovalCode([string]$Action, $Observed, [string]$SnapshotFactsSha256) {
    (Get-Sha256Hex "T501-STEP2|$Action|$($script:PerfDatabase)|$SnapshotFactsSha256|$(@($Observed.Facts) -join "`n")").Substring(0, 12)
}

$script:SchemaChangeApproval = $null

# Records the approval for ONE action when, and only when, the caller named the database and supplied the code of the state that
# was just verified. Anything else stops with no approval recorded.
function Grant-SchemaChangeApproval([string]$Action, [string]$ConfirmDatabase, [string]$SuppliedCode, [string]$ExpectedCode) {
    $script:SchemaChangeApproval = $null
    if ($ConfirmDatabase -cne $script:PerfDatabase) { Stop-Run 'CONFIRM_MISSING' "-ConfirmDatabase $($script:PerfDatabase) is required." }
    if ([string]::IsNullOrWhiteSpace($SuppliedCode)) { Stop-Run 'APPROVAL_REQUIRED' 'No approval code was supplied; the schema was not changed.' }
    if ($SuppliedCode -cne $ExpectedCode) { Stop-Run 'APPROVAL_CODE_MISMATCH' 'The approval code is not the code of the state that was just verified; the schema was not changed.' }
    $script:SchemaChangeApproval = [pscustomobject]@{ Action = $Action; Code = $ExpectedCode; Used = $false }
}

# The sentence a person must type at the console, bound to the action, the database and the code of the verified state.
function Get-StepConfirmationPhrase([string]$Action, [string]$Code) { "I APPROVE $Action ON $($script:PerfDatabase) CODE $Code" }

# The approval code alone is printed by this tool, so whoever can run it can read it. This is the one step a script that has no
# console cannot take: the sentence must be typed by a person at an interactive console. Input or output that is redirected (a
# pipe, a file, a captured or non-interactive run) stops here, before anything is changed. ReadLine is injected for the tests.
function Confirm-StepByHuman([string]$Action, [string]$Code, [bool]$InputRedirected, [bool]$OutputRedirected, [scriptblock]$ReadLine) {
    if ($InputRedirected -or $OutputRedirected) {
        Stop-Run 'HUMAN_CONFIRMATION_REQUIRED' 'The change needs a person at an interactive console to type the confirmation sentence; this run has redirected input or output. Nothing was changed.'
    }
    $phrase = Get-StepConfirmationPhrase $Action $Code
    Write-Host "To confirm, type exactly this sentence and press Enter (anything else stops the run):"
    Write-Host "  $phrase"
    $typed = & $ReadLine
    if ($null -eq $typed -or ([string]$typed).Trim() -cne $phrase) {
        Stop-Run 'HUMAN_CONFIRMATION_MISMATCH' 'The typed sentence is not the confirmation sentence; nothing was changed.'
    }
}

# The arguments of the one schema-changing command. RemoveIndexes migrates down to InitialCreate; RestoreIndexes migrates up.
function Get-EfUpdateArguments([string]$Action) {
    $common = @('--project', 'src/RequestManagement.Infrastructure', '--startup-project', 'src/RequestManagement.Infrastructure', '--no-build', '--no-color')
    switch ($Action) {
        'RemoveIndexes' { return @('ef', 'database', 'update', 'InitialCreate') + $common }
        'RestoreIndexes' { return @('ef', 'database', 'update') + $common }
    }
    Stop-Run 'ACTION_NOT_ALLOWED' "'$Action' is not an action that changes the schema."
}

# THE ONLY place in these scripts that can run `dotnet ef database update`. It needs a grant for exactly this action that has not
# been used yet (it is used up here, before the command starts), and Invoke-ChildProcess in turn needs the guard's approval.
function Invoke-EfDatabaseUpdate([string]$Action, [string]$BackendDir) {
    $grant = $script:SchemaChangeApproval
    if ($null -eq $grant -or $grant.Used) { Stop-Run 'APPROVAL_REQUIRED' 'There is no unused approval for a schema change; nothing was run.' }
    if ($grant.Action -cne $Action) { Stop-Run 'APPROVAL_ACTION_MISMATCH' "The approval is for '$($grant.Action)', not for '$Action'; nothing was run." }
    $grant.Used = $true
    $arguments = Get-EfUpdateArguments $Action
    $run = Invoke-ChildProcess -FileName 'dotnet' -Arguments $arguments -WorkingDirectory $BackendDir -TimeoutSeconds 600
    [pscustomobject]@{ ExitCode = $run.ExitCode; TimedOut = $run.TimedOut; Text = (Hide-Secrets ($run.Stdout + "`n" + $run.Stderr) '').Trim() }
}

# ---- the SQL that Entity Framework must produce ---------------------------------------------------------------------------------------

function ConvertTo-NormalizedEfScript([string]$Text) {
    $lines = @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch 'tools version' })
    ($lines -join "`n") -replace "N'\d+\.\d+\.\d+'", "N'{V}'"
}

# Direction Remove: AddQueryIndexes -> InitialCreate. Direction Restore: InitialCreate -> AddQueryIndexes.
function Get-ExpectedEfScript([string]$Direction) {
    $indexes = @(
        @('IX_Requests_AssignedTo_Status_CreatedAt', '([AssignedTo], [Status], [CreatedAt] DESC)'),
        @('IX_Requests_CreatedAt_Id', '([CreatedAt] DESC, [Id] DESC)'),
        @('IX_Requests_OrganizationName_CreatedAt', '([OrganizationName], [CreatedAt] DESC)'),
        @('IX_Requests_Priority_Status', '([Priority], [Status])'),
        @('IX_Requests_Status_CreatedAt', '([Status], [CreatedAt] DESC) INCLUDE ([Priority])'))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('BEGIN TRANSACTION;')
    if ($Direction -ceq 'Remove') {
        foreach ($i in $indexes) { $lines.Add("DROP INDEX [$($i[0])] ON [Requests];") }
        $lines.Add('DELETE FROM [__EFMigrationsHistory]')
        $lines.Add("WHERE [MigrationId] = N'$($script:StepMigrationIndexes)';")
    }
    elseif ($Direction -ceq 'Restore') {
        foreach ($i in $indexes) { $lines.Add("CREATE INDEX [$($i[0])] ON [Requests] $($i[1]);") }
        $lines.Add('INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])')
        $lines.Add("VALUES (N'$($script:StepMigrationIndexes)', N'{V}');")
    }
    else { throw "unknown direction '$Direction'" }
    $lines.Add('COMMIT;')
    $lines.Add('GO')
    $lines -join "`n"
}

function Test-EfScriptMatches([string]$Direction, [string]$Text) {
    (ConvertTo-NormalizedEfScript $Text) -ceq (ConvertTo-NormalizedEfScript (Get-ExpectedEfScript $Direction))
}

# ---- the original snapshot ----------------------------------------------------------------------------------------------------------

# The facts hash of docs/perf/snapshots/RequestManagement_Perf.pre-step2.txt as taken on 2026-10-27 (the "Facts sha256" header, which
# is recomputed from the facts, never read from the file). Any other snapshot - a retaken one, an edited one, another name - is
# refused by every action that uses a snapshot, so the approval code and the comparison always refer to this recorded state.
$script:StepOriginalSnapshotFactsSha256 = '2FB254016853AB9F508940A6B653053E5E2059B3992E1D4DDDDC30F1385D766E'

# ---- classifying a state that is neither of the two expected ones ------------------------------------------------------------------------

# Looks only at the five query indexes and the AddQueryIndexes history row (the things a removal or a restoration touches), and
# requires everything else to equal the snapshot. Pure: it reads nothing and changes nothing. Class is one of
#   WITH_INDEXES, WITHOUT_INDEXES                       the two expected states (every other fact equals the snapshot)
#   PARTIAL_SOME_INDEXES                                some, not all, of the five exist, the AddQueryIndexes row is present
#   PARTIAL_SOME_INDEXES_HISTORY_MISSING                some, not all, of the five exist, and the row is gone: no routine fix, stop
#   INDEXES_GONE_HISTORY_PRESENT                        none of the five, but the AddQueryIndexes row is still there
#   INDEXES_PRESENT_HISTORY_MISSING                     all five, but the history row is gone: no routine fix, stop. The row is never
#                                                       added by hand because the five indexes look right (see the advice)
#   INDEX_ALTERED                                       an index or the history row exists with other columns, options or version
#   DATA_OR_TARGET_DIFFERS                              anything else differs (rows, checksum, marker, database, other indexes, ...):
#                                                       not an index problem; never repaired by these scripts
function Get-StepStateClassification($Observed, $Snapshot) {
    $names = @((Get-StepQueryIndexLines).Keys)
    $facts = @($Observed.Facts)
    $isTracked = {
        param($Line)
        ($Line -like "migration|$($script:StepMigrationIndexes)|*") -or (@($names | Where-Object { $Line -like "index|Requests|$_|*" }).Count -gt 0)
    }
    $observedOthers = @($facts | Where-Object { -not (& $isTracked $_) })
    $snapshotOthers = @(Get-StepFactsForKind $Snapshot 'WithoutIndexes')
    $otherDifferences = @(Get-StepSetDifference $observedOthers $snapshotOthers).Count + @(Get-StepSetDifference $snapshotOthers $observedOthers).Count
    $result = [ordered]@{ Class = ''; Present = @(); Missing = @(); History = 'absent'; OtherDifferences = $otherDifferences; Sessions = $Observed.Sessions; Unexpected = @($Observed.Unexpected).Count }
    if ($facts.Count -eq 0 -or @($Observed.Unexpected).Count -gt 0 -or $otherDifferences -gt 0) { $result.Class = 'DATA_OR_TARGET_DIFFERS'; return [pscustomobject]$result }

    $snapshotLines = @($Snapshot.Facts)
    $present = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $altered = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $recorded = @($snapshotLines | Where-Object { $_ -like "index|Requests|$name|*" })
        $live = @($facts | Where-Object { $_ -like "index|Requests|$name|*" })
        if ($live.Count -eq 0) { $missing.Add($name) }
        elseif ($live.Count -eq 1 -and $recorded.Count -eq 1 -and $live[0] -ceq $recorded[0]) { $present.Add($name) }
        else { $altered.Add($name) }
    }
    $recordedHistory = @($snapshotLines | Where-Object { $_ -like "migration|$($script:StepMigrationIndexes)|*" })
    $liveHistory = @($facts | Where-Object { $_ -like "migration|$($script:StepMigrationIndexes)|*" })
    if ($liveHistory.Count -eq 0) { $result.History = 'absent' }
    elseif ($liveHistory.Count -eq 1 -and $recordedHistory.Count -eq 1 -and $liveHistory[0] -ceq $recordedHistory[0]) { $result.History = 'present' }
    else { $result.History = 'altered' }
    $result.Present = @($present.ToArray())
    $result.Missing = @($missing.ToArray())
    if ($altered.Count -gt 0 -or $result.History -eq 'altered') { $result.Class = 'INDEX_ALTERED'; $result.Missing = @($missing.ToArray() + $altered.ToArray()); return [pscustomobject]$result }
    $all = $names.Count
    if ($present.Count -eq $all -and $result.History -eq 'present') { $result.Class = 'WITH_INDEXES' }
    elseif ($present.Count -eq 0 -and $result.History -eq 'absent') { $result.Class = 'WITHOUT_INDEXES' }
    elseif ($present.Count -eq 0) { $result.Class = 'INDEXES_GONE_HISTORY_PRESENT' }
    elseif ($present.Count -eq $all) { $result.Class = 'INDEXES_PRESENT_HISTORY_MISSING' }
    elseif ($result.History -eq 'present') { $result.Class = 'PARTIAL_SOME_INDEXES' }
    else { $result.Class = 'PARTIAL_SOME_INDEXES_HISTORY_MISSING' }
    [pscustomobject]$result
}

# What to do about a class. Text only: nothing here is ever run by these scripts.
function Get-StepRecoveryAdvice([string]$Class) {
    switch ($Class) {
        'WITH_INDEXES' { return 'The schema is as recorded (the five indexes and the history row). Nothing to repair.' }
        'WITHOUT_INDEXES' { return 'The five indexes and the history row are gone, everything else is as recorded. If the removal was intended, it is complete; to go back use -Action RestoreIndexes (needs its own approval).' }
        'PARTIAL_SOME_INDEXES' { return 'Only some of the five indexes exist and the history row is present. Manual check needed: wait until no dotnet/sqlcmd child and no other session remain, run -Action Check again, then follow SCHEMA_STEP.md (Recovery). Do not run the EF update command: it cannot fix this state.' }
        'PARTIAL_SOME_INDEXES_HISTORY_MISSING' { return 'STOP. Only some of the five indexes exist and the history row is missing. Neither the EF removal nor the EF restoration is expected to leave this state, so its cause is unknown. Manual investigation is required before ANY change. Do not add the history row by hand and do not run the EF update command.' }
        'INDEXES_GONE_HISTORY_PRESENT' { return 'No index, but the AddQueryIndexes history row is still there. Manual check needed; SCHEMA_STEP.md (Recovery) lists the two ways out (finish the removal by deleting the row, or recreate the five indexes). The EF update command would treat the migration as applied.' }
        'INDEXES_PRESENT_HISTORY_MISSING' { return 'STOP. All five indexes exist as recorded, but the AddQueryIndexes history row is missing. Do not add the row by hand: indexes that look right do not prove that the rest of the schema is what the migration left, because these scripts compare only index definitions, constraint and foreign key names, and the data. Manual investigation is required (SCHEMA_STEP.md, Recovery): find the cause and compare the complete schema; a person decides. The EF update command would fail on the existing index names.' }
        'INDEX_ALTERED' { return 'An index or the history row exists but differs from the snapshot (columns, order, options or ProductVersion). Stop and report; do not repair automatically.' }
        'DATA_OR_TARGET_DIFFERS' { return 'Something other than the five indexes differs from the snapshot (database, marker, rows, checksum, other indexes, ...). This is not an index problem. Stop and report; do not repair automatically.' }
    }
    'Unknown class.'
}

function Format-StepClassification($Classification) {
    $notRecorded = if (@($Classification.Missing).Count -gt 0) { "; not as recorded: $(@($Classification.Missing) -join ', ')" } else { '' }
    $detail = "Classification: $($Classification.Class) (indexes as recorded: $(@($Classification.Present).Count) of 5$notRecorded; AddQueryIndexes history row: $($Classification.History); other differences from the snapshot: $($Classification.OtherDifferences)"
    if ($null -ne $Classification.Sessions -and $Classification.Sessions -ne 0) { $detail += "; $($Classification.Sessions) other session(s) on the database - a command may still be running, wait for it" }
    "$detail). $(Get-StepRecoveryAdvice $Classification.Class)"
}

# Decides whether the state read after a schema change is the expected one. $null means it is. Otherwise the message says, from the
# classification and not from the intended direction, what the schema looks like now and what is safe. Pure.
function Get-StepPostCheckStop($After, [string]$ToKind, $Snapshot) {
    $failures = @(Get-StepGateFailures $After $ToKind $Snapshot)
    if ($failures.Count -eq 0) { return $null }
    $classification = Get-StepStateClassification $After $Snapshot
    $reached = ($classification.Class -ceq 'WITHOUT_INDEXES' -and $ToKind -ceq 'WithoutIndexes') -or ($classification.Class -ceq 'WITH_INDEXES' -and $ToKind -ceq 'WithIndexes')
    $lead = if ($reached) { 'The schema change itself IS complete (the indexes and the history row are as intended); only another check failed, so do not undo it.' } else { "The schema is NOT in the intended state '$ToKind'." }
    "$lead First differences: $(@($failures | Select-Object -First 4) -join ' | '). $(Format-StepClassification $classification) Nothing is repaired automatically."
}
