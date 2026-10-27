# Performance report (T-503)

> **Status.** One run per phase (`before` and `after`), both on 2026-10-27, on 100,000 rows. Every number below is taken from a file under [`results/`](results/); the report was generated from those files and cross-checked against them.
> **Read section 7 first.** In the `after` phase the measurement script marked only **3 of 14** statements `STABLE`; the other **11** are `PLAN_UNSTABLE` and are kept exactly as saved. This report does **not** claim that those plans were stable, and it does **not** claim that every improvement was caused by the indexes. Under the plan's own rule (WORK_PLAN section 5.4) a `PLAN_UNSTABLE` statement is not a valid before/after comparison; its numbers are given here as observations only.

## 1. Environment and provenance

| Item | Value (source: `results/environment.txt`) |
|---|---|
| Commit measured | `cd58ab230f9c5f88a08c5d1f7ddc00b980274255` (`backend/src` had no uncommitted changes) |
| CPU / RAM | 11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz ; physical cores 4 ; logical processors 8 ; 15.7 GB |
| OS | Microsoft Windows 11 Pro 10.0.26300 |
| SQL Server | Microsoft SQL Server 2022 (RTM-CU27-GDR) (KB5126934) - 16.0.4305.5 (X64) , Docker container `request-management-sql` (the same server that hosts the development database; the measured database is `RequestManagement_Perf`) |
| Scripts | `run-sql.ps1`, `measure-api.ps1`, `perf-common.ps1`, `guard-perf-target.ps1` (SHA-256 values are in `environment.txt`) |
| Dataset | 100,000 rows, seed 20261020, checksum -1953119262 ([`results/dataset.txt`](results/dataset.txt)) |

Timestamps in `fidelity.txt` are server time (UTC); the other files use local time (UTC+2 on the measuring machine).

## 2. Method

- **SQL level** (`run-sql.ps1`): for each of the 14 statements (count and data of B1a-B1f, the two GROUP BY queries of B2), 1 warm-up and 5 measured executions with `STATISTICS IO, TIME` on and `XML` off; medians come from those five. One more execution with `XML` on produces the `.sqlplan` only (DEVIATIONS.md, deviation B). Logical reads are for the table `Requests`.
- **API level** (`measure-api.ps1`): the Release build of the API on a loopback port, 10 warm-up and 100 sequential measured calls per scenario, GET only, wall-clock time to read the whole body; p50/p95 by nearest rank. B2 runs twice: with the summary cache enabled and with `SummaryCache__Enabled=false`.
- **Phases:** `before` = the five `AddQueryIndexes` indexes removed (`dotnet ef database update InitialCreate`, through `set-index-state.ps1`); `after` = the five indexes restored (`dotnet ef database update`). Both changes were made with the guarded procedure of `docs/perf/SCHEMA_STEP.md`, with typed confirmation.
- **Scenarios** (WORK_PLAN section 5.1): B1a filtered list, B1b deep page (page 2500), B1c text search `payroll` + `status=New`, B1d sort by `title`, B1e handler queue (`handler-07`, `InProgress`), B1f organization prefix `Aurora`, B2 summary.
- **Not done:** no repeated runs of a phase, so there is no run-to-run variance; the plan cache was not cleared between the phases (see section 7).

## 3. Data and index restoration

Evidence in files:

- `results/before/dataset-check.txt` and `results/after/dataset-check.txt`: 100,000 rows and checksum -1953119262, each marked `match`.
- `results/before/indexes.txt`: none of the five `AddQueryIndexes` indexes present (`Phase check` line). `results/after/indexes.txt`: all five present.
- Every statement returned the same row count in both phases ([section 5](#5-sql-level-logical-reads-cpu-and-plan-shape)). For all statements except the two B2 queries the result hash is also equal; for B2 the hash differs while the row counts are equal (4 and 3 groups). B2 has no `ORDER BY`, and the plan changed from a hash aggregate to a stream aggregate, so a different order of the groups is the likely reason; this was not verified further.

Evidence from the session, not stored in a result file: the console output of `set-index-state.ps1` for the removal (`CHANGE OK ... WithoutIndexes`) and the restoration (`CHANGE OK ... WithIndexes`), and an independent `set-index-state.ps1 -Action Check` after the restoration (`Gate 6 ok: ... WithIndexes`), which compares the live database with the recorded snapshot `docs/perf/snapshots/RequestManagement_Perf.pre-step2.txt` (rows, checksum, distributions, every index and its options, constraints, foreign key, migration history). The snapshot comparison does not compare page counts.

**The restored indexes are not physically identical to the originals.** The definitions are the same, but the indexes were rebuilt, so their size changed:

| Index | Pages in `results/indexes.txt` (2026-10-23) | Pages in `results/after/indexes.txt` |
|---|---|---|
| `IX_Requests_CreatedAt_Id` | 622 | 224 |
| `IX_Requests_Status_CreatedAt` | 657 | 243 |
| `IX_Requests_AssignedTo_Status_CreatedAt` | 1041 | 495 |
| `IX_Requests_OrganizationName_CreatedAt` | 1411 | 732 |
| `IX_Requests_Priority_Status` | 344 | 156 |

This is one more reason not to treat the original index files as a baseline for the `after` numbers.

## 4. API latency (p50 and p95)

Source: `results/before/api.csv`, `results/after/api.csv` (100 measured calls each, all HTTP 200, no failed calls; `total_count` equal in both phases). Times in ms.

| Scenario | Variant | p50 before | p50 after | change | p95 before | p95 after | change |
|---|---|---:|---:|---:|---:|---:|---:|
| B1a | default | 45.741 | 15.905 | -65.2% | 63.858 | 23.639 | -63.0% |
| B1b | default | 167.150 | 120.213 | -28.1% | 229.258 | 185.246 | -19.2% |
| B1c | default | 217.587 | 118.185 | -45.7% | 272.518 | 153.380 | -43.7% |
| B1d | default | 105.473 | 90.612 | -14.1% | 132.792 | 121.789 | -8.3% |
| B1e | default | 60.034 | 25.250 | -57.9% | 79.750 | 34.773 | -56.4% |
| B1f | default | 96.586 | 32.695 | -66.1% | 114.556 | 45.344 | -60.4% |
| B2 | cache-on | 20.509 | 21.930 | +6.9% | 29.632 | 32.507 | +9.7% |
| B2 | cache-off | 67.153 | 40.012 | -40.4% | 82.380 | 46.534 | -43.5% |

These are end-to-end API times (count query + data query + serialisation + HTTP on one machine). They show what the caller saw; they say nothing about plan stability (section 7).

## 5. SQL level: logical reads, CPU and plan shape

Source: `results/<phase>/<scenario>.stats.txt` (medians of 5; CPU and elapsed have a resolution of 1 ms, so `0.0` means below 1 ms) and the saved plans `results/<phase>/<scenario>.<part>.sqlplan`. The plan shape is the list of physical operators and indexes found in the saved plan XML.

| Statement | Rows (b/a) | Same result hash | Reads `Requests` before | after | CPU ms before | after | Elapsed ms before | after | Plan before | Plan after | After verdict |
|---|---|---|---:|---:|---:|---:|---:|---:|---|---|---|
| B1a.count | 1/1 | yes | 2254 | 12 | 11.0 | 0.0 | 13.0 | 0.0 | Stream Aggregate + Clustered Index Scan on PK_Requests | Stream Aggregate + Index Seek on IX_Requests_Status_CreatedAt | PLAN_UNSTABLE |
| B1a.data | 20/20 | yes | 2254 | 1123 | 14.0 | 0.0 | 18.0 | 0.0 | Top + Sort + Clustered Index Scan on PK_Requests | Top + Nested Loops + Index Seek + Clustered Index Seek on IX_Requests_CreatedAt_Id, PK_Requests | PLAN_UNSTABLE |
| B1b.count | 1/1 | yes | 2254 | 153 | 10.0 | 1.0 | 13.0 | 8.0 | Stream Aggregate + Clustered Index Scan on PK_Requests | Stream Aggregate + Index Scan on IX_Requests_Priority_Status | PLAN_UNSTABLE |
| B1b.data | 20/20 | yes | 2368 | 2368 | 313.0 | 279.0 | 120.0 | 91.0 | Top + Parallelism + Sort + Clustered Index Scan on PK_Requests | Top + Parallelism + Sort + Clustered Index Scan on PK_Requests | STABLE |
| B1c.count | 1/1 | yes | 2254 | 2254 | 88.0 | 88.0 | 91.0 | 88.0 | Stream Aggregate + Clustered Index Scan on PK_Requests | Stream Aggregate + Clustered Index Scan on PK_Requests | STABLE |
| B1c.data | 20/20 | yes | 2254 | 8721 | 83.0 | 1.0 | 92.0 | 8.0 | Top + Sort + Clustered Index Scan on PK_Requests | Top + Nested Loops + Index Scan + Clustered Index Seek on IX_Requests_CreatedAt_Id, PK_Requests | PLAN_UNSTABLE |
| B1d.count | 1/1 | yes | 2254 | 153 | 10.0 | 5.0 | 13.0 | 10.0 | Stream Aggregate + Clustered Index Scan on PK_Requests | Stream Aggregate + Index Scan on IX_Requests_Priority_Status | PLAN_UNSTABLE |
| B1d.data | 20/20 | yes | 2368 | 2368 | 326.0 | 245.0 | 49.0 | 39.0 | Top + Parallelism + Sort + Clustered Index Scan on PK_Requests | Top + Parallelism + Sort + Clustered Index Scan on PK_Requests | STABLE |
| B1e.count | 1/1 | yes | 2254 | 7 | 9.0 | 0.0 | 14.0 | 0.0 | Stream Aggregate + Clustered Index Scan on PK_Requests | Stream Aggregate + Index Seek on IX_Requests_AssignedTo_Status_CreatedAt | PLAN_UNSTABLE |
| B1e.data | 20/20 | yes | 2254 | 1554 | 9.0 | 0.0 | 16.0 | 1.0 | Top + Sort + Clustered Index Scan on PK_Requests | Top + Sort + Nested Loops + Index Seek + Clustered Index Seek on IX_Requests_AssignedTo_Status_CreatedAt, PK_Requests | PLAN_UNSTABLE |
| B1f.count | 1/1 | yes | 2254 | 116 | 17.0 | 0.0 | 23.0 | 4.0 | Stream Aggregate + Clustered Index Scan on PK_Requests | Stream Aggregate + Nested Loops + Constant Scan + Index Seek on IX_Requests_OrganizationName_CreatedAt | PLAN_UNSTABLE |
| B1f.data | 20/20 | yes | 2254 | 336 | 33.0 | 0.0 | 36.0 | 0.0 | Top + Sort + Clustered Index Scan on PK_Requests | Top + Nested Loops + Index Scan + Clustered Index Seek on IX_Requests_CreatedAt_Id, PK_Requests | PLAN_UNSTABLE |
| B2.status | 4/4 | no | 2254 | 239 | 19.0 | 7.0 | 22.0 | 12.0 | Hash Match + Clustered Index Scan on PK_Requests | Stream Aggregate + Index Scan on IX_Requests_Status_CreatedAt | PLAN_UNSTABLE |
| B2.priority | 3/3 | no | 2254 | 153 | 20.0 | 11.0 | 26.0 | 12.0 | Hash Match + Clustered Index Scan on PK_Requests | Stream Aggregate + Index Scan on IX_Requests_Priority_Status | PLAN_UNSTABLE |

Recorded, not hidden: for B1c.data the logical reads were not identical in all five runs of the `after` phase (runs 8721,8721,8721,8721,8720); the table shows the median.
Recorded, not hidden: for B1e.data the logical reads were not identical in all five runs of the `after` phase (runs 1554,1553,1554,1553,1554); the table shows the median.
Recorded, not hidden: for B1f.data the logical reads were not identical in all five runs of the `after` phase (runs 336,336,336,336,335); the table shows the median.

## 6. What improved, and the exceptions

### Where the numbers improved

- **B1a** (status + priority + date range). The count went from 2254 to 12 reads, from a clustered index scan to an index seek on `IX_Requests_Status_CreatedAt`. The page query went from 2254 to 1123 reads and from a scan with a sort to a seek on `IX_Requests_CreatedAt_Id` with key lookups and no sort. API p50 45.741 -> 15.905 ms.
- **B1e** (handler queue). Count 2254 -> 7 reads (seek on `IX_Requests_AssignedTo_Status_CreatedAt`); page query 2254 -> 1554 reads (seek, lookups; the plan still has a sort). API p50 60.034 -> 25.250 ms.
- **B1f** (organization starts with `Aurora`). Count 2254 -> 116 reads (seek on `IX_Requests_OrganizationName_CreatedAt`); page query 2254 -> 336 reads (the plan uses `IX_Requests_CreatedAt_Id` and filters through lookups, not the organization index). API p50 96.586 -> 32.695 ms.
- **The count queries of B1b and B1d** (no filter) went from 2254 to 153 reads, a narrow scan of `IX_Requests_Priority_Status` instead of the clustered index.

Interpretation (not proven): these changes are consistent with the new indexes giving the optimizer a narrower or ordered access path, which is what the index design in the README assumed. The saved plans show that the new plans use those indexes; the plan-stability limitation in section 7 applies to most of these statements.

### Exceptions

- **B1c (text search).** The count query did not change at all (`Clustered Index Scan`, 2254 reads, CPU 88.0 -> 88.0 ms, verdict STABLE with the same plan hash as before). This is what a leading-wildcard `LIKE '%payroll%'` allows: no index can seek on it (hypothesis H1). The page query changed plan: it now scans `IX_Requests_CreatedAt_Id` in order and looks rows up until it has 20 matches, so CPU fell from 83.0 to 1.0 ms while the logical reads **rose** from 2254 to 8721. The API p50 fell from 217.587 to 118.185 ms. The reads depend on how far into the ordered index the 20 matches lie, so this plan is a trade-off of reads for CPU and could be worse for a rarer search term.
- **B1b (deep page, offset 49,980).** The page query is **unchanged**: `Clustered Index Scan` with a parallel sort, 2368 reads in both phases, verdict STABLE with the same plan hash. Its CPU median moved from 313.0 to 279.0 ms and the API p50 from 167.150 to 120.213 ms. Since the page query did not change, part of the API difference comes from its count query (now 153 reads) and part may be noise: there was one run per phase, so this report cannot separate them.
- **B1d (sort by `title`).** There is no index on `Title`; the page query is unchanged (scan + parallel sort, 2368 reads, verdict STABLE with the same hash). Only its count query improved (2254 -> 153 reads). API p50 105.473 -> 90.612 ms, which is mostly the count query.

### B2 (summary), cache enabled and disabled

- **SQL level.** The two GROUP BY queries went from 2254 and 2254 reads (clustered scan with a hash aggregate) to 239 and 153 reads (a scan of `IX_Requests_Status_CreatedAt` and `IX_Requests_Priority_Status` with a stream aggregate). Both are `PLAN_UNSTABLE` in the `after` phase.
- **API, cache enabled.** p50 20.509 -> 21.930 ms and p95 29.632 -> 32.507 ms: no improvement, as expected, because after the first call the response is served from the cache and does not reach the database. The 60 s expiry never elapsed during a 110-call run, so these calls measure the cached path.
- **API, cache disabled.** p50 67.153 -> 40.012 ms and p95 82.380 -> 46.534 ms. With the indexes the uncached path is closer to the cached one (40.012 vs 21.930 ms at p50) than before (67.153 vs 20.509 ms). The cache is still faster, so it keeps its value, but the margin is smaller.

## 7. Plan-stability limitation (fidelity)

The script accepts the saved plan as the plan of the timed runs only if the plan cache holds exactly **one** `query_plan_hash` for the statement and it equals the hash of the saved plan (`results/<phase>/fidelity.txt`).

- **before:** 14 of 14 statements `STABLE`.
- **after:** 3 of 14 statements `STABLE` (B1b.data, B1c.count, B1d.data); 11 are **`PLAN_UNSTABLE`**: B1a.count, B1a.data, B1b.count, B1c.data, B1d.count, B1e.count, B1e.data, B1f.count, B1f.data, B2.status, B2.priority.

`PLAN_UNSTABLE` is left exactly as saved. `fidelity.txt` and the other result files were not edited, and the plan cache was not cleared and the measurements were not repeated.

| Statement | Verdict before | Verdict after | Hashes in cache (after) | Executions of the saved hash (after) |
|---|---|---|---:|---:|
| B1a.count | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B1a.data | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B1b.count | STABLE | PLAN_UNSTABLE | 3 | 7 |
| B1b.data | STABLE | STABLE | 1 | 117 |
| B1c.count | STABLE | STABLE | 1 | 116 |
| B1c.data | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B1d.count | STABLE | PLAN_UNSTABLE | 3 | 14 |
| B1d.data | STABLE | STABLE | 1 | 117 |
| B1e.count | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B1e.data | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B1f.count | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B1f.data | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B2.status | STABLE | PLAN_UNSTABLE | 2 | 7 |
| B2.priority | STABLE | PLAN_UNSTABLE | 2 | 7 |

**What the files show.** For each `PLAN_UNSTABLE` statement the cache lists two or more hashes: the hash of the plan saved in the `after` phase (7 executions, which is 1 warm-up + 5 measured + 1 XML execution), and at least one other hash with many more executions (for example 110 for the data queries of B1a and B1e, which is 10 warm-up + 100 measured calls) whose first execution time (15:02 to 15:04 UTC) falls in the `before` API run. The three `STABLE` statements (B1b.data, B1c.count, B1d.data) are exactly those whose plan did not change between the phases (same hash in both phases).

**Possible explanation (not proof).** The statements have the same text in both phases, so the plan cache may still hold the `before` plans next to the new ones; if that is so, the extra hash is the old plan from the `before` API run and every `after` execution used the new plan. The counts fit this reading, but the script cannot tell it apart from real plan instability, and this report does not claim either. Part of the matching may also depend on how the script finds a statement in the cache by its text; that was not examined.

**Analysis of the saved `after/fidelity.txt` (2026-10-27, from the files only; no database access, nothing re-measured).** The lookup (`Get-FidelityQuery` in `perf-common.ps1`) takes every plan-cache entry of the current database whose text *contains* the statement (`CHARINDEX`), API executions included, and groups them by `query_plan_hash` with `SUM(execution_count)`, `MIN(creation_time)` and `MAX(last_execution_time)`. The verdict is therefore `PLAN_UNSTABLE` whenever any such entry has another hash, whether or not it ran during the timed runs. The saved timestamps show what the other hashes are:

- For 10 of the 11 `PLAN_UNSTABLE` statements the saved-plan hash has exactly 7 executions (1 warm-up + 5 measured + 1 XML run, which are the `run-sql.ps1 -Phase after` executions; the pair B1b.count/B1d.count has the same text, so 14 = 2 x 7), and every other hash was **last executed before the saved hash was first compiled** (15:02 to 15:04 UTC, the `before` API run, against 15:11 UTC for the `after` SQL runs). Those other hashes are leftovers of the `before` phase (110 executions = 10 warm-up + 100 API calls), still listed in the cache.
- B1b.count and B1d.count also list `0xCFD6EE123D595684` and `0x4FE1EC1855E1015D` with last-execution times (15:11:24.300 and 15:11:29.663) that are exactly the last-execution times of B1a.count's and B1c.count's own entries. Their text contains the shorter text of these two statements (`SELECT COUNT(*) ... FROM Requests`, with and without a `WHERE`), so the substring match picked up other statements' runs.
- **Reading.** In all 11 cases the executions of the `after` timed runs are the executions of the saved plan. This is consistent with the logical reads, which were identical in all 5 measured runs (within 1 page for three statements, recorded in section 5). It remains an inference from timestamps, not a repeated measurement: the verdicts in `fidelity.txt` are unchanged, and it says nothing about the API-level timings of section 4, whose plans are not in the cache at the time of the capture (the `after` API run came after it).

**What this does and does not allow.**

- The logical reads, CPU and elapsed medians (section 5) and the API times (section 4) are measured values and are reported as measured.
- They do **not** establish that the `after` plans were the same in all timed executions for the `PLAN_UNSTABLE` statements, and they do not establish that the improvement was caused by the indexes alone. Other factors that this design did not control: the state of the data and plan cache (warm in both phases), one run per phase, and the machine load.
- Under WORK_PLAN section 5.4 the `PLAN_UNSTABLE` statements are not a valid before/after comparison. The honest reading of sections 4 to 6 is: the saved plans show the new indexes being used, and the measured numbers moved in the direction the index design predicted, with the exceptions described above.

## 8. Hypotheses (WORK_PLAN section 5.5)

| ID | Hypothesis | State | Basis |
|---|---|---|---|
| H1 | Contains search (B1c) cannot seek on an index | **Supported** | B1c.count has the same `Clustered Index Scan` plan and 2254 reads in both phases (verdict `STABLE` in both, same hash). |
| H2 | The cost of B1b grows with the offset | **Not tested** | Only one offset (49,980) was measured. B1b.data reads 2368 in both phases and the optimizer does not use an index for it. No comparison across offsets exists. |
| H3 | The count query dominates the cost of B1a | **Not supported** | In `before` the count and the page query read the same 2254 pages and the CPU medians are 11.0 and 14.0 ms. In `after` the page query reads more (1123 vs 12). |
| H4 | B2 scans a narrow index once the indexes exist | **Supported by the saved plans, with the section 7 limitation** | The saved `after` plans scan `IX_Requests_Status_CreatedAt` and `IX_Requests_Priority_Status` (239 and 153 reads vs 2254 and 2254); both statements are `PLAN_UNSTABLE`. |

## 9. Indexes and the evidence for each

Each index is used in at least one saved `after` plan. This is evidence of use, not a measured isolated benefit (no index was dropped on its own and re-measured).

| Index | Used by (saved `after` plans) | Reads before -> after |
|---|---|---|
| `IX_Requests_CreatedAt_Id` | B1a.data, B1c.data, B1f.data | B1a.data 2254 -> 1123; B1c.data 2254 -> 8721; B1f.data 2254 -> 336 |
| `IX_Requests_Status_CreatedAt` | B1a.count, B2.status | B1a.count 2254 -> 12; B2.status 2254 -> 239 |
| `IX_Requests_AssignedTo_Status_CreatedAt` | B1e.count, B1e.data | B1e.count 2254 -> 7; B1e.data 2254 -> 1554 |
| `IX_Requests_OrganizationName_CreatedAt` | B1f.count (not B1f.data) | B1f.count 2254 -> 116 |
| `IX_Requests_Priority_Status` | B1b.count, B1d.count, B2.priority | B1b.count 2254 -> 153; B2.priority 2254 -> 153 |

**Decision (T-502, WORK_PLAN section 5.4: keep an index if it reduces logical reads or removes a scan or sort for its scenario).** All five stay; none is dropped, so `AddQueryIndexes` is unchanged.

| Index | Decision | Reason from the files |
|---|---|---|
| `IX_Requests_CreatedAt_Id` | keep | Removes the scan and sort of B1a.data (2254 -> 1123) and B1f.data (2254 -> 336). Trade-off recorded for B1c.data (reads 2254 -> 8721, CPU 83 -> 1 ms). |
| `IX_Requests_Status_CreatedAt` | keep | B1a.count 2254 -> 12 (seek); B2.status 2254 -> 239. |
| `IX_Requests_AssignedTo_Status_CreatedAt` | keep | B1e.count 2254 -> 7 (seek); B1e.data 2254 -> 1554. |
| `IX_Requests_OrganizationName_CreatedAt` | keep | B1f.count 2254 -> 116 (seek). Not used by B1f.data. |
| `IX_Requests_Priority_Status` | keep | B1b.count and B1d.count 2254 -> 153; B2.priority 2254 -> 153 (narrow scan). |

Limits of this decision: the comparison is between the two phases, not an isolated one-index-at-a-time measurement; the `PLAN_UNSTABLE` verdicts stay as saved and are read as described at the end of section 7; no write cost was measured.

Write cost of the indexes (R6.3) was not measured.

## 10. Bottlenecks and proposed improvements (not implemented, not measured)

- **Contains search (B1c, H1).** The count query scans every row. Candidates: SQL Server full-text search, or a minimum search length together with selective filters. The page-query plan trades reads for CPU (section 6), which depends on the term.
- **Sort by `title` (B1d) and the deep page (B1b).** Both still scan and sort. Candidates: an index on `Title` (for B1d) with its write cost, and keyset pagination instead of `OFFSET` (for B1b, H2 untested).
- **Count queries.** They are a second statement per list request. Candidate: skip or approximate the count after the first page (H3 is not supported by these data, so this is a lower priority).

## 11. How loading all rows into memory is avoided (R1.10, R6.5)

- Each list request runs two statements (`docs/perf/sql/B1a.sql` to `B1f.sql`): a `COUNT` and a page query with `WHERE`, `ORDER BY` and `OFFSET/FETCH`. Filtering, sorting and paging therefore happen in SQL Server, not in the API and not in the browser.
- The saved statistics confirm the size of what leaves the database: every page query returned 20 rows and every count query 1 row, in both phases (the page size is 20). The two B2 queries return one row per status (4) and per priority (3).
- The page queries select only the nine columns of the DTO (checked by the unit test `PerfSqlCaptureTests`); no entity is loaded or tracked.
- What the database itself reads is a different matter: section 5 shows scans of all 2254 pages of `Requests` for several statements in the `before` phase. That is work inside SQL Server, which the indexes reduce for some statements; it is not application memory.

## 12. Files

| Path | Content |
|---|---|
| `results/dataset.txt`, `results/indexes.txt`, `results/provenance.txt` | Dataset creation and the first index listing (2026-10-23) |
| `results/environment.txt` | Environment, commit, script and SQL file hashes (written once, in the `before` run) |
| `results/before/`, `results/after/` | `indexes.txt`, `dataset-check.txt`, `fidelity.txt`, 7 `*.stats.txt`, 14 `*.sqlplan`, `api.csv`, `api-calls.csv`, `api-run.txt` |
| `docs/perf/sql/` | The captured SQL of B1a-B1f and B2 |
| `DEVIATIONS.md` | Differences from the plan and the offline and live test notes |
