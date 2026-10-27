# T-501: temporary deviations from the work plan

Status (2026-10-27): accepted by the project owner on 2026-10-23; **A and B are now reconciled in `docs/WORK_PLAN.md`** (§5.2 steps 2, 3 and 5, §5.3, T-501 acceptance criteria). C was not adopted. D is a new, **still unreconciled** note (the plan was not changed for it). E (scenarios B1e and B1f) is a plan extension and is written into §5.1.

| Item | State |
|---|---|
| A: one `.sqlplan` per statement | Reconciled in the plan (§5.3 row for the plan files; T-501 acceptance). |
| B: timings measured with `STATISTICS XML` off, plus one extra XML execution | Reconciled in the plan (§5.2 step 3). The wording on `query_plan_hash` and `fidelity.txt` was added with it. |
| C: separate p50/p95 file | Not adopted (unchanged). |
| D: dataset created with `run-seeder.ps1 -Mode Execute` / `--create-new`, not `Seeder --reset` | **Open.** §5.2 step 1 still says `--reset`. The record is `results/dataset.txt`. `results/seeder-run.txt` was never created (the wrapper stopped after the Seeder finished; see `dataset.txt`). |
| E: scenarios B1e and B1f added | Written into §5.1 of the plan (approved 2026-10-27). |

The plan's own status for T-501 to T-503 was not changed by this reconciliation: no measurement result exists yet.

## Deviation A: one `.sqlplan` per statement, not per scenario

- **Plan (§5.3):** `results/<phase>/<scenario>.sqlplan`.
- **Done instead:** `results/<phase>/<scenario>.<part>.sqlplan`, where `<part>` is `count` or `data` for B1a to B1d, and `status` or `priority` for B2.
- **Why:** every scenario runs two statements, and `SET STATISTICS XML ON` returns one `ShowPlanXML` document per statement. A scenario-level file would have to merge several documents into one, which SSMS does not open as a single plan.
- **Consequences:**
  - The acceptance check "every scenario has stats files, plans and an API CSV" must match `<scenario>.*.sqlplan`, not `<scenario>.sqlplan`.
  - The traceability rows R6.1 and R6.2 point at `.sqlplan` and `.stats.txt` files; the pattern is the only difference.
  - T-502 must use the same names for the "after" phase, or the before/after diff will not line up.
  - `.stats.txt` stays one file per scenario (IO and TIME for all its statements).

## Deviation B: timings are measured without `STATISTICS XML`

- **Plan (§5.2 step 3):** one warm-up and five measured runs, each with `SET STATISTICS IO, TIME ON` and `SET STATISTICS XML ON`.
- **Done instead:**
  - One warm-up and five measured runs with `SET STATISTICS IO, TIME ON` and **XML off**. The logical reads, CPU and elapsed time in `.stats.txt` (and the median of five) come from these runs only.
  - **One additional execution** with `SET STATISTICS IO, TIME, XML ON`, used only for the `.sqlplan` files. Its own IO and TIME output is kept in the stats file under a separate heading and is **not** used for the medians.
- **Why:** serialising the actual plan adds work to every execution and would inflate CPU and elapsed time, the two secondary metrics.
- **Consequences:**
  - No statement may say that IO or TIME were measured with XML on. They were measured with it off, in different executions from the plan.
  - Plan and timings come from different executions. The plan is accepted as the plan of the timed runs only if `query_plan_hash` is the same for all of them; `results/before/fidelity.txt` will show this. If it differs, the scenario is reported as "plan unstable" and not as a before/after comparison.
  - Logical reads are expected to be identical in the six executions. A difference is recorded, not hidden.

## Not adopted: Deviation C (separate p50/p95 file)

`api.csv` keeps the p50 and p95 required by §5.3. An additional file with the individual calls may be added; it does not replace the percentiles in `api.csv`.

## Deviation D: the dataset was created with `--create-new`, not `--reset`

- **Plan (§5.2 step 1):** `Seeder --reset --count 100000`.
- **Done instead:** `docs/perf/run-seeder.ps1 -Mode Execute` ran the Seeder with `--create-new --expect-server localhost,1433 --expect-database RequestManagement_Perf --count 100000 --seed 20261020 --batch-size 10000` (2026-10-23). `--create-new` creates the database and refuses an existing one; `--reset` drops it, which is never offered for the performance database.
- **Why:** `RequestManagement_Perf` shares the server with the development database, and the Seeder guards (`--expect-*`) make a wrong target impossible. `--reset` would drop a database.
- **Consequences:** same seed, count and checksum (`-1953119262`), so the data is identical to a `--reset` run. The `T501_PERF_DB` marker was written by hand with the statement the script uses (`dataset.txt`, section 2), and `seeder-run.txt` does not exist. **Not reconciled** in `WORK_PLAN.md`.

## Deviation E: two extra scenarios, B1e and B1f

- **Plan (§5.1) before:** B1a to B1d and B2.
- **Added (2026-10-27, approved by the project owner):** B1e = `assignedTo=handler-07&status=InProgress&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20`; B1f = `organizationName=Aurora&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20`.
- **Why:** no earlier scenario filters by `AssignedTo` or `OrganizationName`, so the indexes `IX_Requests_AssignedTo_Status_CreatedAt` and `IX_Requests_OrganizationName_CreatedAt` could not be judged under §5.4.
- **What changed:** `PerfSqlCaptureTests` (two scenarios and their assertions), `docs/perf/sql/B1e.sql` and `B1f.sql` (generated by that unit test, no database; commit header `9db54a1`), the scenario list and six approved hashes in `perf-common.ps1`, the `-Scenario` validation of `run-sql.ps1` and `measure-api.ps1`, and the expectations in `test-perf-scripts.ps1`. The other five SQL files and their hashes are unchanged (their text was regenerated into a temporary folder and compared: identical).
- **Consequences:** the expected files per phase are now `B1a` to `B1f` with `count` and `data` plans (12 plans) plus `B2.status` and `B2.priority` (14 plan files), `<scenario>.stats.txt` for 7 scenarios, and 8 rows in `api.csv` (B1a to B1f, B2 cache-on, B2 cache-off). No measurement exists yet for any of them.

## Offline test results (2026-10-27)

These are offline self-tests of the scripts. They are **not** performance results and **not** a live run: no database connection was opened and no `sqlcmd`, Seeder, migration or benchmark was run.

| Test | Result | What it covers |
|---|---|---|
| `docs/perf/test-perf-scripts.ps1` | 572 of 572 cases behaved as expected, after the B1e/B1f changes and the correction of the expected number of planned API calls from 6 to 8 | Helpers, parameter and target checks, the approved-hash table (21 entries), the read-only SQL grammar, `-DryRun` of `run-sql.ps1` and `measure-api.ps1` (no process started, nothing written), the index-state procedure against fake `docker`/`sqlcmd`/`dotnet` programs |
| `docs/perf/test-guard.ps1` | 18 of 18 cases behaved as expected | The target guard: 16 must-stop and 2 must-pass connection strings, decided by the static checks alone |

The suite's own list of what it does not cover still applies (see the header of `test-perf-scripts.ps1`): the shape of real `sqlcmd` output, the T-SQL of the index listing, the plan-cache and schema-state queries, the guard against a real container, the API start and port-ownership query, and the typing of the confirmation sentence at a real console. Two defects of that kind were found earlier only in a live run (`SCHEMA_STEP.md`), so the first live run of `run-sql.ps1` and `measure-api.ps1` may still reveal others.

Not done yet: any live run of `run-sql.ps1` or `measure-api.ps1`, the removal and restoration of the five indexes, and every measurement of T-501 to T-503. The statement above that no measurement exists yet is unchanged.
