# T-501: temporary deviations from the work plan

Status: **provisional**, accepted by the project owner on 2026-10-23. `docs/WORK_PLAN.md` (§5.2, §5.3) has **not** been changed.
They must be reconciled with the plan (or reverted) before T-501 is marked Done. This file is the only place that describes them.

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
