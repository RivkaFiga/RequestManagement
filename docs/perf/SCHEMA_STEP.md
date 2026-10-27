# T-501 step 2: removing and restoring the five `AddQueryIndexes` indexes

Procedure for `RequestManagement_Perf` only. Script: `set-index-state.ps1`, library: `perf-schema-step.ps1`, tests: `test-perf-scripts.ps1` (groups D and E, offline).

**Status: prepared, not run. No schema change has been approved or made.** The baseline snapshot was taken on 2026-10-27 (SELECT only) and all gates pass against the live database in the state *with* the indexes. `-Action RemoveIndexes` without `-Execute` was run live and stopped before the change, as designed.

## Prerequisites

- Docker container `request-management-sql` running and healthy.
- `ConnectionStrings__RequestManagement` set in the process that runs the script, exactly `localhost,1433` / `RequestManagement_Perf`. It is never printed.
- The EF design-time build is newer than its sources (the script never builds).

## Steps (run in an interactive PowerShell console)

1. **Baseline** (done; SELECT only; `docs/perf/snapshots/RequestManagement_Perf.pre-step2.txt`, never under `results/`):
   `powershell.exe -File docs\perf\set-index-state.ps1 -Action Snapshot`
   It records the marker, row count, checksum, distributions, bounds, migration history, every index with every option, constraints and the foreign key. It refuses to replace an existing snapshot without `-Overwrite`.
2. **Check** (writes nothing): `-Action Check` prints the approval code of the verified state.
3. **Stop before the change**: `-Action RemoveIndexes` runs every gate and stops, printing the code. This is the default.
4. **Change** (only after a separate explicit approval): `-Action RemoveIndexes -Execute -ConfirmDatabase RequestManagement_Perf -ApprovalCode <code>`, then type the confirmation sentence the script prints.
5. **Restore**: the mirror image, `-Action RestoreIndexes`, from the state without the indexes back to the snapshot.

## Gates (any failure stops; nothing is repaired automatically)

Parameters and target (offline) → tools by full path and fresh EF build → `guard-perf-target.ps1 -CheckServer` (container, server, database, `T501_PERF_DB` marker) → `dotnet ef dbcontext info` names `RequestManagement_Perf` on `localhost,1433` → the removal and restoration SQL, generated offline, equals the expected text → one SELECT batch: marker, 100,000 rows, checksum `-1953119262`, distributions, bounds, migrations, indexes, constraints, foreign key, no other session, equality with the snapshot. Gate 6 is read again after the approval and right before the command, and once more after it (the state must be exactly the expected one).

## What enforces the approval, and what does not

- `dotnet ef database update` exists in one function (`Invoke-EfDatabaseUpdate`), reachable only through `Invoke-StepChange` after the code check and the human confirmation. Tests check this statically, and group E runs the whole script against fake `docker`/`sqlcmd`/`dotnet` programs and shows that no run, normal or stopped, ever starts it.
- The approval code is derived from the verified state, the action and the snapshot, but the script itself prints it, so **the code alone proves nothing about a person**.
- The extra barrier is the typed confirmation sentence, which needs an interactive console: redirected input or output stops the run with `HUMAN_CONFIRMATION_REQUIRED`. That stops scripted and captured runs.
- **Limit:** this does not stop whoever has an interactive console and chooses to type the sentence, including an automated agent that is given a real terminal. The guarantee is "no unattended, scripted or accidental change", not tamper-proofing. The decision to approve belongs to a person, and the script cannot prove that one made it.

## Tests

`powershell.exe -File docs\perf\test-perf-scripts.ps1` (offline: no database, no Docker, no `dotnet ef database update`). The EF SQL for the removal and the restoration is generated without a connection and compared with the expected text.

Group E puts a small compiled stub on `PATH` (in the temporary folder, for the child processes only) under the names `docker`, `sqlcmd` and `dotnet`. It answers from files and logs each call; it has no answer for `ef database update`. Cases: normal path stops before the change; right code without a console; wrong or foreign codes; every state gate through the real script; container exited, unhealthy or not publishing the port; marker missing; wrong EF context or SQL; the Snapshot action (create-only, no secrets).

## Defects found while preparing the live baseline (fixed in `perf-common.ps1`)

- `Invoke-PerfSqlcmd` passed `-X`, which makes `sqlcmd` ignore `SQLCMDPASSWORD` (verified: "Login failed for user 'sa'"). Now `-X` is not used; the child gets `SQLCMDPASSWORD` and every other `SQLCMD*` variable is removed.
- The schema-state and index-listing queries failed with Msg 451 (collation conflict between `sysname` columns and catalog `*_desc` columns). The `*_desc` columns are now cast and given `COLLATE DATABASE_DEFAULT`.

Both defects are shared with `run-sql.ps1`/`measure-api.ps1` (same function); the earlier offline tests could not see them.

## Cannot pick the development database by mistake

- The target comes only from `ConnectionStrings__RequestManagement`, and must be exactly `localhost,1433` / `RequestManagement_Perf` (case-sensitive; `RequestManagement`, `RequestManagement_SeedCheck`, another port or host stop with `TARGET_MISMATCH`, tested).
- `dotnet ef dbcontext info` (gate 4) and `dotnet ef database update` run with the same environment and the same `--project/--startup-project`, so the database that gate 4 names is the one the update would use. `--connection` is never passed.
- `DesignTimeDbContextFactory` falls back to `Database=RequestManagement` (the development database, without credentials) when the variable is **not** set. The script refuses to start without the variable (`ENV_MISSING`), but **never run `dotnet ef database update` by hand** in a shell where the variable is not set.
- `-ConfirmDatabase RequestManagement_Perf` must be given verbatim; the typed sentence and the approval code both contain the database name.
- The manual SQL below starts with a guard that throws unless `DB_NAME()` is `RequestManagement_Perf` and the `T501_PERF_DB` marker exists, and `sqlcmd` is called with `-d RequestManagement_Perf`.

## Recovery (instructions only; the scripts never repair anything)

Rules: stop at the first unexpected result; take no second action before reading the state; use `-Action Check` (read-only) and the SELECT below to read it; passwords only through `SQLCMDPASSWORD`, never `-P`.

**Reading the state reliably.** `-Action Check` (and every `GATE_FAILED` / `POST_CHECK_FAILED` stop) prints `Classification: <class>` computed from the live facts against the snapshot. It looks at the five indexes one by one (exact line, so a changed key, option or version counts as altered) and at the `AddQueryIndexes` history row, and requires everything else (database, marker, rows, checksum, distributions, bounds, other indexes, constraints, foreign key) to equal the snapshot:

| Class | Meaning | Safe next step |
|---|---|---|
| `WITH_INDEXES` / `WITHOUT_INDEXES` | one of the two expected states | none needed (`WITHOUT_INDEXES` after an intended removal means it is complete) |
| `PARTIAL_SOME_INDEXES` | some, not all, of the five exist, history row present | manual: table below |
| `PARTIAL_SOME_INDEXES_HISTORY_MISSING` | some, not all, of the five exist, history row gone | **STOP**: manual investigation, no routine fix |
| `INDEXES_GONE_HISTORY_PRESENT` | no index, history row still there | manual: table below |
| `INDEXES_PRESENT_HISTORY_MISSING` | all five as recorded, history row gone | **STOP**: manual investigation, no routine fix. The row is **not** added by hand (see "History row missing") |
| `INDEX_ALTERED` | an index or the history row differs from the snapshot | stop and report |
| `DATA_OR_TARGET_DIFFERS` | anything else differs (wrong database, marker, rows, checksum, ...) | stop and report; not an index problem |

The classification never depends on whether the removal command finished: it is computed from the database and the snapshot only. The restoration likewise starts from the live state and the snapshot, not from any record of the removal.

**A post-check that fails.** The message begins with either `The schema change itself IS complete` (class equals the intended state; only another check failed, for example another session was connected: do **not** undo it, run `-Action Check` when the session is gone) or `The schema is NOT in the intended state` (follow the class). It no longer tells you to run the restoration blindly.

**An interrupted run.** Closing the window or killing the script does not stop a `dotnet ef` worker that already started (it runs in a hidden console of its own), so it may still commit or roll back by itself. A run that times out stops the whole process tree. Before anything else:

```powershell
Get-Process dotnet, sqlcmd -ErrorAction SilentlyContinue | Select-Object Id, StartTime, Path
```

and wait until nothing started by the run remains and the SELECT below shows `other_sessions` = 0 (SQL Server rolls a killed connection back), then `-Action Check`. Never start the second command while the first may still be running.

**Restoration prerequisites** (it does not need the removal to have "succeeded"): the original snapshot file, an EF Debug build newer than its sources (otherwise `EF_BUILD_STALE`: rebuild the Infrastructure project by hand, this is not a database change), the same EF package version as in the snapshot (`ProductVersion` 10.0.13). Keep a copy of the snapshot outside the repository tree; its SHA256 is in the next paragraph. If the script cannot be used, fix the cause (rebuild, restore the snapshot copy) rather than creating the indexes by hand: indexes created by hand leave the history row missing, which is the state the next section stops on.

**The snapshot is pinned.** The scripts accept only a snapshot whose facts hash is `2FB254016853AB9F508940A6B653053E5E2059B3992E1D4DDDDC30F1385D766E` (recomputed from the facts, never read from the header); any other file is refused with `SNAPSHOT_NOT_ORIGINAL` before a process is started. File SHA256 at the time of writing: `786191022A8C6E4A523B44E6E98FE77E36BAD7F1400A7AE3D0A970EEF306D457`. Retaking the snapshot on purpose means updating `$script:StepOriginalSnapshotFactsSha256` in `perf-schema-step.ps1`.

Read the state (SELECT only):

```sql
SET NOCOUNT ON;
SELECT DB_NAME() AS db;
SELECT i.name, (SELECT COUNT(*) FROM sys.dm_exec_sessions s WHERE s.database_id = DB_ID() AND s.session_id <> @@SPID) AS other_sessions
FROM sys.indexes i WHERE i.object_id = OBJECT_ID(N'dbo.Requests') AND i.index_id > 0 ORDER BY i.name;
SELECT MigrationId, ProductVersion FROM dbo.__EFMigrationsHistory ORDER BY MigrationId;
SELECT COUNT_BIG(*) AS rows, CHECKSUM_AGG(CHECKSUM([Id],[Title],[OrganizationName],[Status],[Priority],[AssignedTo],[CreatedAt],[UpdatedAt])) AS checksum FROM dbo.Requests;
```

The target is `Requests` with `PK_Requests` plus the five `IX_Requests_*` indexes and migration rows `InitialCreate` and `AddQueryIndexes` (state WithIndexes), or the same without the five indexes and without the `AddQueryIndexes` row (state WithoutIndexes). Rows must be 100000 and the checksum -1953119262 in both.

| What happened | State to expect | What to do |
|---|---|---|
| The removal failed before it changed anything (gate failure, tool error, refused confirmation) | WithIndexes, `Check` passes | Nothing to repair. Read the reason, fix it, ask for a new approval. |
| The removal command ran and failed or was interrupted (window closed, timeout) | EF runs a migration's commands in one transaction (EF behaviour; **not exercised here, so not proven**), so WithIndexes (rolled back) or WithoutIndexes (committed) is expected; anything else is reported by the classification | First wait until no `dotnet`/`sqlcmd` child is still running and `other_sessions` is 0 (see "An interrupted run"). Then `-Action Check`. If the class is `WITH_INDEXES` or `WITHOUT_INDEXES`, continue from that state; otherwise follow the class. |
| The removal succeeded but the post-check failed | classification says | `schema change itself IS complete`: keep it, find the other reason (a session, ...). `NOT in the intended state`: follow the class; never retry the command. |
| Partial result anyway: k of the five indexes missing, the `AddQueryIndexes` row still there (class `PARTIAL_SOME_INDEXES`) | neither | Only after a fresh `Check` still says `PARTIAL_SOME_INDEXES` and a new approval: return to the baseline with the `CREATE INDEX` lines of the missing indexes only (the present ones were already proven identical to the snapshot). Do not run `dotnet ef database update` (it treats the migration as applied). |
| Indexes all gone, the `AddQueryIndexes` row still there (class `INDEXES_GONE_HISTORY_PRESENT`) | neither | Only after a fresh `Check` still says so and a new approval: either finish the removal with the `DELETE` statement below (this is exactly the last statement of the EF removal script; the result is the proven `WITHOUT_INDEXES` state), or return to baseline by creating all five. |
| A restoration (`RestoreIndexes`) failed or was interrupted | WithoutIndexes (rolled back) or WithIndexes (committed) | Same as above: wait, `Check`, and if still WithoutIndexes fix the cause (disk space: the five indexes are about 4,100 pages, roughly 32 MB; lock wait; session on the database) and ask for a new approval. |
| Some or all of the five indexes present, the history row missing (class `PARTIAL_SOME_INDEXES_HISTORY_MISSING` or `INDEXES_PRESENT_HISTORY_MISSING`) | neither; not produced by the EF removal or restoration | **STOP.** No statement below applies. See "History row missing". |

Manual statements (the exact text of the EF scripts, which the tests compare with the migrations). Save the chosen lines as a `.sql` file in a temporary folder, with this guard first, and run it with `sqlcmd -S localhost,1433 -U sa -C -b -d RequestManagement_Perf -i <file>` after `$env:SQLCMDPASSWORD` is set in that console:

```sql
SET XACT_ABORT ON;
IF DB_NAME() <> N'RequestManagement_Perf'
   OR NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0 AND name = N'T501_PERF_DB' AND CAST(value AS nvarchar(100)) = N'RequestManagement.T-501')
    THROW 50001, N'Not the T-501 performance database; nothing was run.', 1;
BEGIN TRANSACTION;
-- only the lines that are needed:
CREATE INDEX [IX_Requests_AssignedTo_Status_CreatedAt] ON [Requests] ([AssignedTo], [Status], [CreatedAt] DESC);
CREATE INDEX [IX_Requests_CreatedAt_Id] ON [Requests] ([CreatedAt] DESC, [Id] DESC);
CREATE INDEX [IX_Requests_OrganizationName_CreatedAt] ON [Requests] ([OrganizationName], [CreatedAt] DESC);
CREATE INDEX [IX_Requests_Priority_Status] ON [Requests] ([Priority], [Status]);
CREATE INDEX [IX_Requests_Status_CreatedAt] ON [Requests] ([Status], [CreatedAt] DESC) INCLUDE ([Priority]);
-- only for class INDEXES_GONE_HISTORY_PRESENT, to finish a removal:
-- DELETE FROM [__EFMigrationsHistory] WHERE [MigrationId] = N'20261020183100_AddQueryIndexes';
COMMIT;
```

There is no statement that adds the `AddQueryIndexes` row, on purpose.

After any manual statement: `-Action Check` must pass (it compares with the snapshot, including index options, row count, checksum and the history). If it does not, stop and ask. Manual statements are a change to the database and need the same separate approval as the procedure itself, and a fresh `Check` immediately before, showing the class the statement is meant for.

### History row missing (classes `INDEXES_PRESENT_HISTORY_MISSING`, `PARTIAL_SOME_INDEXES_HISTORY_MISSING`)

Do not add the row because the five indexes exist. What the scripts compare (the `SchemaState` query) is: database, marker, row count, checksum, distributions, bounds, every index with all its options, the **names** of the CHECK constraints, the foreign key's name and delete action, migration rows and sessions. They do **not** capture columns (types, nullability, defaults, collation), CHECK expressions, foreign key columns, triggers, statistics or filegroups. Index lines equal to the snapshot therefore do not prove that the schema is what `AddQueryIndexes` (and `InitialCreate` before it) left, and a hand-written history row would make EF believe it is. Without that proof, stop:

1. `-Action Check` and keep the output (the first differences and the classification).
2. Find the cause (who ran what, when): the `__EFMigrationsHistory` table is the only thing EF reads, so a missing row means something outside the scripts touched it.
3. Compare the **complete** schema with the one the migrations produce (`dotnet ef migrations script 0 AddQueryIndexes`, generated offline) at the level above: columns, defaults, CHECK expressions, foreign key, triggers, statistics, filegroups. If anything cannot be proven identical, nothing is changed.
4. Only a person decides what follows. If everything is proven identical, the route that never writes a history row by hand is to bring the schema to the proven `WITHOUT_INDEXES` state with the five `DROP INDEX` statements of the EF removal script (without its `DELETE`), then run the normal `-Action RestoreIndexes`, which creates the indexes and writes the row itself. That is a database change and needs its own explicit approval.
If the data itself is damaged (rows or checksum differ), do not repair: the data set can only be recreated by the Seeder (seed 20261020), which needs a dropped database and its own explicit approval.

Version pin: the restoration writes `ProductVersion` of the EF runtime in the Infrastructure build (now `10.0.13`, as in the snapshot). If the EF package version changes before the restoration, the post-check differs from the snapshot on that one line and fails; it is a reason to stop, not to repair automatically.

## Not covered

The T-SQL of the plan-cache (fidelity) query and the real behaviour of the post-change state read have not run live. The typed confirmation at a real console is covered only through the injected-reader function.
