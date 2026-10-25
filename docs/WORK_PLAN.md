# Work Plan: Request Management System (Full Stack Take-Home)

| Item | Value |
|---|---|
| Document status | Draft v2, reviewed against the assignment PDF. **Implementation has started: Phase 0–1 (foundation, data layer, seeder) is in the repository; Phase 2 is partly implemented (the `Api` project with the search, summary, status-update, history and bulk endpoints exists; only the tasks marked `Done` below were verified). The Angular scaffold (T-301) exists; the rest of Angular, performance and docs do not exist yet.** |
| Date | 2026-10-20 |
| Verification (local) | 2026-10-21: `dotnet build .\RequestManagement.sln --no-restore` succeeded. Unit tests 51 passed, 0 failed. Integration tests 8 passed, 0 failed (Docker Testcontainers, SQL Server 2022). `dotnet list .\RequestManagement.sln package --vulnerable --include-transitive`: no vulnerable packages in all five projects. 2026-10-22 (T-205): build 0 warnings, `dotnet format --verify-no-changes` clean, unit tests 124 passed, integration tests 75 passed, 0 failed. 2026-10-22 (T-206): unit tests 127 passed, integration tests 82 passed, 0 failed. 2026-10-22 (T-201, T-202): build 0 warnings, `dotnet format --verify-no-changes` clean, unit tests 165 passed, integration tests 131 passed, 0 failed. The status of every task is the one in its block in §7. |
| Source of truth | Assignment PDF: Full Stack developer test, level C (6 pages, Hebrew) |
| Status convention | `Planned` → `In Progress` → `Done (evidence: <commit / test run / file>)`. A task becomes `Done` only when its evidence exists and is linked. |
| Estimates | Focused-effort estimates in hours. They are not commitments. |

---

## 1. Current State (Inspection Findings)

| # | Finding | Impact on plan |
|---|---|---|
| F1 | *Original finding (2026-10-20, now superseded):* the folder contained only this plan. *As of 2026-10-21 the repository holds* a Git history (commit `37c3e5a`, `origin` = GitHub, branch `main`), the `Core`, `Infrastructure` and `Seeder` projects, two migrations, and 33 test methods in the unit and integration projects. There is no `Api` project and no `frontend/`. | Greenfield for Phases 2–3 only. |
| F2 | The host toolchain could not be inspected. The inspection shell runs in a Linux VM attached to the machine, not in Windows. In that VM: Node `22.23.2`, npm `10.9.8`, Git `2.34.1`; `dotnet`, `ng`, `docker` and `sqlcmd` were **not found**. | These versions may not represent the Windows host. T-001 confirms the host versions, including whether Docker is available, before anything is pinned. |
| F3 | The folder path contains non-ASCII characters and a space (`C:\Users\משתמש חדש\Desktop\AAA`). | Risk for npm, Angular and Docker tooling (R-07). Develop in an ASCII path such as `C:\dev\request-management`. |
| F4 | The PDF leaves several behaviours unspecified. | Recorded as assumptions in §3.2. They are not presented as requirements. |

---

## 2. Requirements Catalogue (explicit, from the PDF)

Section numbers follow the PDF. Labels:
- **Must**: the PDF marks the section as mandatory ("חובה").
- **Scored**: the PDF evaluates the item but does not mark it Must.
- **Context**: background statements that drive other requirements.

There are 77 catalogue entries in total.

### General / Data (task description, "Goals" and the scoring table)
- **R0.1** (Scored) .NET / .NET Core backend: layering, DI, async work, error handling.
- **R0.2** The request entity has these fields: `Id`, `Title`, `OrganizationName`, `Status` (New, InProgress, Waiting, Completed), `Priority` (Low, Medium, High), `AssignedTo` (handler id or name), `CreatedAt`, `UpdatedAt`, `RowVersion/Version` (a field that detects competing updates).
- **R0.3** At least 100,000 records for testing.
- **R0.4** The database is the candidate's choice (SQL Server, MongoDB or an alternative).
- **R0.5** Test data can be regenerated.
- **R0.6** (Context) The system has many concurrent users and a large volume of requests.

### 1. Data retrieval (Must)
- **R1.1** A .NET REST API for retrieval. All records must not be transferred to the client for filtering, sorting or paging.
- **R1.2** Server-side pagination.
- **R1.3** Combined filtering by at least Status, Priority, OrganizationName, AssignedTo and a date range.
- **R1.4** Text search on at least Title and OrganizationName.
- **R1.5** Sorting by at least 3 fields, Asc/Desc.
- **R1.6** At least 2 relevant aggregations.
- **R1.7** A page-size limit and parameter validation.
- **R1.8** `CancellationToken` in the relevant I/O operations.
- **R1.9** The API returns DTOs, not DB entities.
- **R1.10** Document how loading all data into memory is avoided, and how indexes support the main search and filter scenarios.

### 2. Status update and concurrency (Must)
- **R2.1** A request that doesn't exist returns a suitable HTTP code.
- **R2.2** An invalid status, or a transition that isn't allowed, returns a clear validation error.
- **R2.3** Optimistic concurrency: when updates compete, only one valid update succeeds and the other receives a Conflict. PDF §5 names this response as HTTP **409**.
- **R2.4** `UpdatedAt` and `Version/RowVersion` are updated consistently.
- **R2.5** No lost updates.

### 3. Change history (Must)
- **R3.1** An audit record for every status change, with at least `RequestId`, `PreviousStatus`, `NewStatus`, `ChangedAt` and `ChangedBy`.
- **R3.2** An endpoint to view a request's change history.

### 4. Bulk (Must)
- **R4.1** An endpoint that updates the status of up to 100 requests in one call.
- **R4.2** Define and document the behaviour when some requests don't exist or fail because of concurrency.
- **R4.3** Choose All-or-Nothing or Partial Success, justify the choice, and return a clear response.

### 5. Angular (Must)
- **R5.1** Server-side search, filtering, sorting and paging.
- **R5.2** Debounced search.
- **R5.3** Previous requests are cancelled or replaced when the search changes quickly.
- **R5.4** Loading, Empty and Error states.
- **R5.5** Status update with handling of 409 Conflict.
- **R5.6** Display aggregations.
- **R5.7** View change history.
- **R5.8** Separation of responsibility between Components and Services.

### 6. Performance (Must)
- **R6.1** Choose at least 2 central API operations and document how their efficiency was tested on the 100,000 records.
- **R6.2** A query/execution plan, an EXPLAIN, or at least one equivalent metric.
- **R6.3** The indexes added, and the reason for each.
- **R6.4** A possible bottleneck and a proposed improvement.
- **R6.5** No full load before filtering or pagination when the database can do the work.

### 7. Cache (Must, limited scope)
- **R7.1** A cache for at least one aggregate, or another justified read scenario.
- **R7.2** An expiration setting.
- **R7.3** Invalidation that prevents stale data after an update.
- **R7.4** The reasoning for what is cached.
- **R7.5** A *description* of the adjustments needed with multiple server instances.

### 8. Automated tests (Must)
- **R8.1** At least 4 meaningful automated tests, at least 1 of them an integration test.
- **R8.2** A happy-path scenario for retrieval/filtering or for an update.
- **R8.3** A validation / invalid-input test.
- **R8.4** A concurrency conflict test.
- **R8.5** An integration test that covers the API plus the database, or a suitable substitute.

### 9. Work planning (Must)
- **R9.1** A logical breakdown into work units (Feature / User Story / Task or equivalent).
- **R9.2** For each task, what is required and the expected deliverable.
- **R9.3** Execution order and dependencies.
- **R9.4** An effort estimate per task or work unit.
- **R9.5** A clear link between the assignment requirements and the tasks.
- **R9.6** Non-coding tasks: DB design, tests, performance, documentation, run readiness.

### 10. Code quality (Scored)
- **R10.1** Clear project structure and separation of concerns.
- **R10.2** Readable code, consistent naming, no duplication.
- **R10.3** Clear DTOs, models and mapping.
- **R10.4** DI with correct lifetimes.
- **R10.5** Correct async usage.
- **R10.6** Global error handling / ProblemDetails, or an equivalent.
- **R10.7** Consistent validation.
- **R10.8** Logging at meaningful points without exposing sensitive data.
- **R10.9** No over-engineering.

### 11. Documentation (Must)
- **R11.1** Clear instructions to understand and run the solution.
- **R11.2** Technologies and versions.
- **R11.3** Solution structure.
- **R11.4** Database choice and indexes.
- **R11.5** Concurrency and bulk update.
- **R11.6** Cache and invalidation.
- **R11.7** Two significant technical decisions, with the alternatives considered.
- **R11.8** One known limitation and one thing that could be improved.
- **R11.9** AI usage: which parts used AI, and what was checked or changed manually.

### Submission
- **RS.1** Reviewers can fully and conveniently examine the system, source code, work plan, implementation and decisions.
- **RS.2** The submission contains all components and can be run.
- **RS.3** No ZIP files or source code attached to an email.
- **RS.4** AI use is permitted. The candidate is responsible for all submitted code.

**Scoring cautions** from the PDF, treated as hard constraints:
- Client-side filtering, sorting or paging is heavily penalised.
- Concurrency enforced only in the UI is incomplete.
- A cache without invalidation does not get full marks.
- A shallow task breakdown does not get full marks.
- Over-engineering is not an advantage.

---

## 3. Requirements vs. Assumptions vs. Decisions

### 3.1 Requirements
Only the items in §2. Anything not listed there is an assumption (§3.2) or a decision (§3.3).

### 3.2 Assumptions: ambiguities the PDF does not resolve

Each assumption has a default that is applied unless the assignment owner says otherwise.

| ID | What the PDF leaves open | Default applied |
|---|---|---|
| A1 | Requires rejecting "disallowed transitions" but does not define which transitions are allowed. | `New → InProgress \| Waiting`; `InProgress → Waiting \| Completed`; `Waiting → InProgress \| Completed`. `Completed` is terminal. Setting the same status again is disallowed. Defined only in `StatusTransitionPolicy` and exposed as `allowedNextStatuses`. |
| A2 | Requires `ChangedBy` but defines no users or authentication. | An `X-User-Name` request header (≤ 100 characters). Defaults to `"anonymous"` when missing. The value is client-supplied and not authenticated (a known limitation, R-14). |
| A3 | `AssignedTo` is described as a "handler id or name". | Free text, nullable (unassigned allowed). There is no Users table. |
| A4 | Requires "at least 2 relevant aggregations" but sets neither their scope nor which ones. | Global counts by Status and by Priority, plus the total. They ignore the list filters. |
| A5 | Requires "text search" but does not define match semantics. | Case-insensitive *contains*, matching Title OR OrganizationName. 2–100 characters. `LIKE` wildcards in user input are escaped. |
| A6 | Does not define how the filters match. | OrganizationName: starts-with. AssignedTo: exact. Status and Priority: multi-value. All filters combine with AND. |
| A7 | Requires a "date range" without naming the field. | `CreatedAt`, in UTC. `createdFrom` is inclusive and `createdTo` is exclusive. |
| A8 | Requires a page-size limit without giving a value. | Maximum 100, default 20. |
| A9 | Mentions concurrency failures in bulk updates, but not how the client supplies versions. | Every bulk item must carry its own `rowVersion`. |
| A10 | Mentions only status changes as write operations. | No endpoints to create, edit or delete requests. |
| A11 | Says nothing about history for seeded data. | Seeded requests have no history rows. History starts with the first API change. |
| A12 | Exact tool versions. | Proposed: .NET 10 (LTS) / EF Core 10, the current stable Angular, and the Node LTS that Angular supports. Pinned in T-001. |
| A13 | Forbids ZIP and email, but names no submission channel. | A GitHub repository the reviewers can access. |
| A14 | UI language. | English, left-to-right. |

### 3.3 Implementation decisions

These are design choices. Infrastructure beyond the bare minimum is justified in the "Why" column.

| ID | Decision | Why | Alternatives considered |
|---|---|---|---|
| D1 | **SQL Server 2022** with EF Core and a native `rowversion` column. The development database runs in a Docker container. | `rowversion` is maintained by the database, so concurrency detection is enforced server-side, as the scoring cautions demand. EF Core translates filtering, sorting and paging to SQL. Execution plans are easy to capture. Docker avoids a local SQL Server install. | MongoDB with a manual version field. PostgreSQL with `xmin`. Dapper with hand-written SQL. |
| D2 | **Bulk update uses Partial Success.** One transaction per item; the response returns an outcome per item. | Requests are independent, so one stale item should not block 99 valid ones. Per-item transactions keep lock duration short. | All-or-Nothing: simpler semantics, but a single conflict forces the user to redo the whole batch. |
| D3 | **Cache only the global summary.** A concrete `RequestSummaryCache` class built on `IMemoryCache`. 60 s absolute expiration. Invalidated after each commit, with a generation guard (§4.5). | It is read by every user, aggregates 100,000 rows, has a tiny payload, and changes only on status updates, so the invalidation points are well defined. The guard closes a real race in about 10 lines. Redis is only *described*, because R7.5 asks for a description, not an implementation. | Caching list queries: unbounded keys, low hit rate. Redis now: unnecessary infrastructure. |
| D4 | **Layout: three projects, `Api`, `Core`, `Infrastructure`, plus a thin `Seeder` console.** Interfaces exist only at the Api→Infrastructure service boundary. | Layering is scored (R0.1). The seeding logic lives in `Infrastructure`, so the test fixture can reuse it, and the console lets it run independently of the API. No generic repository, mediator or CQRS. | A single project: weaker layering. Clean Architecture with 5+ projects: over-engineering. |
| D5 | **Controllers with `[ApiController]`**, validated with DataAnnotations, `IValidatableObject` and explicit enum checks. | Built-in automatic 400 `ValidationProblemDetails`, no extra packages, one validation mechanism. | Minimal APIs with filters. FluentValidation. |
| D6 | **The `rowVersion` concurrency token (base64) travels in the request body.** | Easy to send from Angular and Swagger UI. Lets the server return the 409 the PDF requires. | `If-Match` with 412: idiomatic HTTP, but 412 is not the 409 the PDF names. |
| D7 | **HTTP status mapping.** 409 for a concurrency conflict is *required* (PDF §5). The rest are decisions: 404 for a missing request; 400 for malformed input or an invalid enum value; 422 for a disallowed transition; bulk returns 200 with per-item outcomes; errors use `ProblemDetails` (500 without internals). Status changes use `PATCH`. | Distinct codes let the client react reliably: retry with fresh data on 409, show the rule on 422, fix the input on 400. | 400 for disallowed transitions too. 207 Multi-Status for bulk (a WebDAV-specific code). |
| D8 | **Offset pagination** (`page`, `pageSize`) with `totalCount`, and `Id` as the tie-breaker. | Matches a page-number paginator. Adequate at 100,000 rows. Deep pages are measured (B1b). | Keyset pagination: offered as an improvement (R6.4, R11.8). |
| D9 | **Angular standalone components with Angular Material** (table, paginator, sort, dialog, snackbar). A page-level facade service built on RxJS. | Material supports server-side sort and paging out of the box, which saves building them. Visual design is not scored. | Plain HTML: no dependency, more manual work. NgRx: over-engineering. |
| D10 | **Deterministic seeding with `SqlBulkCopy`**, a fixed random seed and a fixed anchor date. `--reset` drops the database and re-applies the migrations. | Identical data and IDs on every run (R0.5). Loads 100,000 rows in seconds. | EF `AddRange` at startup: slower, and tied to the API lifecycle. |
| D11 | **Integration-test database:** Testcontainers SQL Server as the primary path. An env-var connection string is the only alternative (§6.2). | Concurrency and `LIKE` behaviour need real SQL Server. | EF InMemory or SQLite: neither has `rowversion` semantics, so concurrency tests would be meaningless. |
| D12 | **xUnit with built-in asserts.** No FluentAssertions. | FluentAssertions v8+ requires a commercial licence for commercial use. | Shouldly. |
| D13 | **The built-in OpenAPI document, with Swagger UI in Development only.** | Reviewers need a convenient way to call the bulk endpoint, which has no UI (RS.1). It costs a single package. | A committed `.http` file. |
| D14 | **Indexes go in a separate migration (`AddQueryIndexes`)**, apart from `InitialCreate`. | Gives a reproducible "before" and "after" for the performance comparison, using standard `dotnet ef` commands (§5). | Hand-written drop/create scripts. |

---

## 4. Architecture

### 4.1 Structure and DI

```
request-management/
├─ backend/  RequestManagement.sln, global.json, .config/dotnet-tools.json (dotnet-ef)
│  ├─ src/ RequestManagement.Api | .Core | .Infrastructure | .Seeder
│  └─ tests/ RequestManagement.UnitTests | .IntegrationTests
├─ frontend/                     Angular app
├─ docs/  WORK_PLAN.md, PERFORMANCE.md, perf/ (sql/, scripts, results/)
├─ docker-compose.yml            SQL Server
└─ README.md
```

**Project references:**
- `Api` → `Core`, `Infrastructure`
- `Infrastructure` → `Core`
- `Core` references neither EF Core nor ASP.NET.

**DI lifetimes:**

| Service | Lifetime |
|---|---|
| `AppDbContext` | Scoped |
| Request services | Scoped |
| `IMemoryCache` | Singleton |
| `RequestSummaryCache` | Singleton (thread-safe) |
| `TimeProvider` | Singleton (`TimeProvider.System`) |
| `StatusTransitionPolicy` | Singleton (stateless) |

### 4.2 API contract

| Method | Route | Success | Error codes |
|---|---|---|---|
| GET | `/api/requests` | 200 `PagedResult<RequestDto>` | 400 |
| GET | `/api/requests/{id}` | 200 `RequestDto` | 404 |
| PATCH | `/api/requests/{id}/status` | 200 `RequestDto` (with the new `rowVersion`) | 400, 404, **409**, 422 |
| GET | `/api/requests/{id}/history` | 200 `StatusHistoryEntryDto[]` (newest first) | 404 |
| POST | `/api/requests/bulk-status` | 200 `BulkStatusUpdateResultDto` | 400 |
| GET | `/api/requests/summary` | 200 `RequestSummaryDto` (cached) | n/a |

Status codes other than 409 are decision D7. Every error body is `application/problem+json`.

**Query parameters for `GET /api/requests`:**

| Parameter | Rule |
|---|---|
| `page` | ≥ 1, default 1 |
| `pageSize` | 1–100, default 20 (A8) |
| `search` | 2–100 characters (A5) |
| `status[]`, `priority[]` | Defined values only. `Enum.IsDefined` is checked, because a number such as `status=7` would otherwise bind without error. |
| `organizationName` | ≤ 200 characters |
| `assignedTo` | ≤ 100 characters |
| `createdFrom`, `createdTo` | from ≤ to (A7) |
| `sortBy` | `createdAt` (default), `updatedAt`, `priority`, `status`, `title` |
| `sortDirection` | `asc` or `desc` (default `desc`) |

**DTOs** live in `Core`. Mapping is done with LINQ `Select` projections, so no entity leaves the data layer.

| DTO | Fields |
|---|---|
| `RequestDto` | `id`, `title`, `organizationName`, `status`, `priority`, `assignedTo`, `createdAt`, `updatedAt`, `rowVersion`, `allowedNextStatuses[]` |
| `PagedResult<T>` | `items`, `page`, `pageSize`, `totalCount`, `totalPages` |
| `UpdateStatusRequest` | `status`, `rowVersion` (both required) |
| `StatusHistoryEntryDto` | `id`, `requestId`, `previousStatus`, `newStatus`, `changedAt`, `changedBy` |
| `BulkStatusUpdateRequest` | `status`, `items[] { id, rowVersion }` (1–100 items, distinct IDs) |
| `BulkStatusUpdateResultDto` | `requested`, `succeeded`, `failed`, `results[] { id, outcome: Updated \| NotFound \| Conflict \| InvalidTransition, rowVersion?, error? }` |
| `RequestSummaryDto` | `total`, `byStatus[]`, `byPriority[]`, `generatedAt` |

Enums are serialised as strings. A 409 response includes `currentStatus` and `currentRowVersion`.

### 4.3 Data model, migrations, seeding

**`Requests` table:**

| Column | Type / constraint |
|---|---|
| `Id` | `int IDENTITY`, clustered PK |
| `Title` | `nvarchar(200)` |
| `OrganizationName` | `nvarchar(200)` |
| `Status` | `tinyint`, CHECK 1–4 |
| `Priority` | `tinyint`, CHECK 1–3. Ordinal values, so sorting by priority is meaningful. |
| `AssignedTo` | `nvarchar(100)`, NULL allowed |
| `CreatedAt`, `UpdatedAt` | `datetime2(3)`, UTC |
| `RowVersion` | `rowversion` |

**`RequestStatusHistory` table:**

| Column | Type / constraint |
|---|---|
| `Id` | `bigint IDENTITY` |
| `RequestId` | FK to `Requests`, no cascade |
| `PreviousStatus`, `NewStatus` | `tinyint` |
| `ChangedAt` | `datetime2(3)` |
| `ChangedBy` | `nvarchar(100)` |
| Index | `(RequestId, ChangedAt DESC)`, created in `InitialCreate` |

**Migrations:**
- `InitialCreate`: tables, primary keys, foreign keys, CHECK constraints, and the history index.
- `AddQueryIndexes`: the secondary indexes on `Requests` (D14).

**Index hypothesis for `AddQueryIndexes`.** T-502 keeps an index only if it shows a measured benefit or has a stated reason, because each index adds write cost.

| Index | Intended scenario |
|---|---|
| `(CreatedAt DESC, Id DESC)` | Default sort, date range, deep pages (B1b) |
| `(Status, CreatedAt DESC) INCLUDE (Priority)` | Status filter with the default sort; GROUP BY Status (B1a, B2) |
| `(AssignedTo, Status, CreatedAt DESC)` | A handler's queue |
| `(OrganizationName, CreatedAt DESC)` | Organization starts-with filter |
| `(Priority, Status)` | GROUP BY Priority (B2) |

Indexes for sorting by `Title` or `UpdatedAt` are added only if B1d or a measurement justifies them.

**Seeding (D10).** The seeding logic generates:
- about 2,000 organizations and about 50 handlers, with about 15% of requests unassigned;
- skewed Status and Priority distributions;
- `CreatedAt` values spread over 24 months before the anchor date.

Rows are loaded with `SqlBulkCopy` in batches of 10,000. The seeder then prints the row count, the distribution, and a `CHECKSUM_AGG` over the business columns.

### 4.4 Status update, concurrency, audit and transaction boundaries

**Single update:**
1. Load the entity. If it is missing, return 404.
2. If the client's `rowVersion` doesn't match, return 409 immediately.
3. If the transition is disallowed (A1), return 422.
4. Set `Status` and `UpdatedAt = TimeProvider.GetUtcNow()`. Set the original `RowVersion` to the client's value. Add the history row, with `ChangedBy` from A2.
5. Call `SaveChangesAsync(ct)`. This is one implicit transaction: `UPDATE … WHERE Id = @id AND RowVersion = @rv`, followed by the history `INSERT`. If no row is affected, EF raises `DbUpdateConcurrencyException`, which becomes 409.

So the update and its audit row are always committed together, and a stale version can never overwrite newer data.

**After commit:** invalidate the summary cache, and log `RequestId`, `From`, `To` and `ChangedBy`. Bodies and connection strings are never logged.

**Bulk update (D2, A9):**
1. Validate the request envelope. If it is invalid, return 400 for the whole request.
2. Load all items with one `WHERE Id IN (…)` query. Missing items get the outcome `NotFound`.
3. Run each item through the same per-item logic as the single update (shared code, no duplication), in its own `SaveChanges`. A conflict produces `Conflict` and clears that item from the change tracker. A disallowed transition produces `InvalidTransition`.
4. If at least one item succeeded, invalidate the cache once.
5. Return 200 with the outcomes.

### 4.5 Cache and invalidation (D3)
- **Key:** `requests:summary`.
- **Configuration:** `SummaryCache:ExpirationSeconds` (default 60) and `SummaryCache:Enabled` (default true). The flag exists only to measure the uncached path in B2.
- **Invalidation:** the services call `Invalidate()` after every successful commit, for both single and bulk updates.
- **Race guard:** a generation counter is incremented on every invalidation. A computed value is stored only if the generation is unchanged since the computation started. This stops a slow read from writing pre-update counts back after an invalidation.
- **Scale-out (documentation only, R7.5):**
  - An in-memory cache is local to each instance, so other instances would stay stale until expiry.
  - Recommended fix: a shared Redis entry via `IDistributedCache`, removed on every update.
  - Alternative: `HybridCache` with Redis as L2, plus pub/sub eviction of each instance's L1.
  - Fallback: a short expiration as the only staleness bound.

### 4.6 Out of scope
- Authentication and authorisation.
- Creating, editing or deleting requests (A10).
- Real-time push.
- Cloud deployment.
- i18n / RTL.
- Full-text search setup (an improvement only).
- CORS: not needed, because the Angular dev proxy keeps everything same-origin.

### 4.7 Angular

| Unit | Responsibility |
|---|---|
| `models/*.ts` | Typed DTOs matching §4.2, plus `ApiError` parsed from ProblemDetails |
| `RequestsApiService` | The only user of HttpClient. Stateless. |
| `RequestsListFacade` (provided by the page) | Manages the list query (pipeline below) |
| `RequestsPageComponent` | Container. Wires the facade to the presentational components. |
| `RequestFiltersComponent`, `RequestsTableComponent` | Presentational. The table is bound to the facade's items array. `MatTableDataSource` sorting and paging are **not** used, so no data is processed client-side. |
| `SummaryPanelComponent` | Shows the aggregations. Refreshes after a successful update. |
| `StatusChangeComponent` | Offers only `allowedNextStatuses`. On 409: shows a message and reloads the row, with **no automatic retry**. On 422 or 400: shows the server message. |
| `RequestHistoryDialogComponent` | History list with loading, empty and error states |
| `httpErrorInterceptor` | Converts error responses to `ApiError` |

**`RequestsListFacade` query pipeline:**
- The search box is debounced: `debounceTime(300)`, then `distinctUntilChanged`.
- Filter, sort and page changes apply immediately, and any filter change resets to page 1.
- Each query goes through `switchMap(api.search)`, so a newer query cancels the request still in flight.
- The facade exposes a state of `loading`, `loaded` (empty when there are no items) or `error` (with a retry action).

The Angular dev server proxies `/api` to the backend.

---

## 5. Performance Measurement Plan (reproducible)

No results exist yet. Every number in `PERFORMANCE.md` must come from a file in `docs/perf/results/`.

### 5.1 Scenarios

All scenarios run against the fixed dataset: `--reset --count 100000` with the seeder's fixed seed and anchor date.

| ID | Operation | Fixed parameters |
|---|---|---|
| B1a | `GET /api/requests`, filtered | `status=InProgress&priority=High`, `createdFrom` = anchor − 90 days, `createdTo` = anchor, sort `createdAt` desc, page 1, size 20 |
| B1b | `GET /api/requests`, deep page | No filters, sort `createdAt` desc, `page=2500&pageSize=20` (offset 49,980) |
| B1c | `GET /api/requests`, text search | `search=<term>&status=New`, page 1, size 20. The term is taken from the seed vocabulary and fixed in the script in T-501. |
| B1d | `GET /api/requests`, alternate sort | No filters, sort `title` asc, page 1, size 20 |
| B2 | `GET /api/requests/summary` | SQL level: the two GROUP BY queries. API level: cache enabled vs. `SummaryCache__Enabled=false`. |

B1 (the main list query) and B2 (the aggregation) are the two central operations R6.1 requires.

### 5.2 Procedure
1. Run `Seeder --reset --count 100000`. This applies all migrations. Save the row count and checksum to `results/dataset.txt`.
2. **Before:** run `dotnet ef database update InitialCreate`, which removes `AddQueryIndexes`. Save the `sys.indexes` listing to `results/before/indexes.txt`.
3. Run `docs/perf/run-sql.ps1 -Phase before`. For each `docs/perf/sql/<scenario>.sql` (both the data query and the count query), it runs 1 warm-up and 5 measured executions via `sqlcmd`, with `SET STATISTICS IO, TIME ON` and `SET STATISTICS XML ON`.
4. Run `docs/perf/measure-api.ps1 -Phase before` against the API in the Release configuration, with logging at Warning. It makes 10 warm-up calls and then 100 sequential calls per scenario, writing a CSV of per-call timings and p50/p95.
5. **After:** run `dotnet ef database update`, which re-applies the indexes. Save the index listing, then repeat steps 3 and 4 with `-Phase after`.
6. Record the environment in `results/environment.txt`: CPU, RAM, OS, `SELECT @@VERSION`, Docker or native, and the commit hash.

The files in `docs/perf/sql/` hold the exact SQL that EF generates for the fixed parameters, captured with `ToQueryString()`. They must be re-captured if the query code changes; T-501 records the commit hash they were taken from.

### 5.3 Metrics and artifacts

| Metric | Source | Saved as |
|---|---|---|
| Logical reads per table (primary: deterministic for the same data and plan) | `STATISTICS IO` | `results/<phase>/<scenario>.stats.txt` |
| CPU and elapsed time, median of 5 (secondary: depends on the environment) | `STATISTICS TIME` | same file |
| Actual execution plan: scan or seek, key lookups, sorts, warnings | `STATISTICS XML` | `results/<phase>/<scenario>.sqlplan` |
| Rows returned (correctness check) | query output | the stats file |
| API p50 / p95 latency | `measure-api.ps1` | `results/<phase>/api.csv` |

### 5.4 Comparison rules
- Results are compared only between phases measured on the same machine, the same dataset checksum and the same SQL files.
- The returned row counts must be identical before and after, or the comparison is invalid.
- `PERFORMANCE.md` shows one table per scenario: logical reads, CPU, elapsed, plan shape and p50/p95, before vs. after. Cells with no artifact say "not measured".
- An index is kept only if it reduces logical reads or removes a scan or sort for its scenario, or if it has a stated non-performance reason.

### 5.5 Hypotheses to test (not results)

| ID | Hypothesis | Improvement to propose if confirmed |
|---|---|---|
| H1 | Contains search (B1c) cannot seek on an index. | Full-text search, or keeping a minimum search length with selective filters |
| H2 | The cost of B1b grows with the offset. | Keyset pagination |
| H3 | The count query dominates the cost of B1a. | Skip or approximate the count after page 1 |
| H4 | B2 scans a narrow index instead of the clustered index once the indexes are added. | n/a |

---

## 6. Test Strategy

### 6.1 Test catalogue

| ID | Level | Scenario | Requirements |
|---|---|---|---|
| UT-1 | Unit | `StatusTransitionPolicy`: all 16 status pairs | R2.2 |
| UT-2 | Unit | Query validation: pageSize 0 and 101, page 0, unknown `sortBy`, from > to, undefined enum value | R1.5, R1.7, R8.3 |
| UT-3 | Unit | Bulk envelope validation: 0 items, 101 items, duplicate IDs | R4.1, R8.3 |
| UT-4 | Unit | Summary cache: hit, expiry, recompute after invalidation, generation guard | R7.1–R7.3 |
| IT-1 | Integration | Combined filters, search, 3 sort fields asc/desc, paging and `totalCount` are correct; `pageSize=500` returns 400 | R1.2–R1.5, R1.7, R8.2, R8.5 |
| IT-2 | Integration | Successful update returns 200; `UpdatedAt` advances; `RowVersion` changes; exactly one correct history row | R2.4, R3.1, R8.2 |
| IT-3 | Integration | Stale `rowVersion` returns 409; the row and its history are unchanged | R2.3, R2.5, R8.4 |
| IT-4 | Integration | Two parallel updates with the same version (synchronised start): exactly one 200 and one 409 | R2.3, R8.4 |
| IT-5 | Integration | 404 for a missing request; 422 for a disallowed transition; 400 for an invalid value; every error is `application/problem+json` | R2.1, R2.2, R8.3, R10.6 |
| IT-6 | Integration | Mixed bulk (valid, missing, stale, disallowed): the outcome per item is correct, only valid rows change, history rows = successes | R4.1–R4.3, R3.1 |
| IT-7 | Integration | Summary, then an update, then summary again: the count difference matches the update | R1.6, R7.3 |
| IT-8 | Integration | History is newest first; 404 for an unknown request | R3.2, R2.1 |
| FE-1 | Angular | Rapid search input: one call after the debounce, carrying the expected query params; a superseded request is cancelled (`HttpTestingController`) | R5.1–R5.3 |
| FE-2 | Angular | A 409 on a status change shows the conflict message and reloads the row; no automatic retry | R5.5, R2.5 |
| FE-3 | Angular | The facade emits loading → loaded, loading → empty, and loading → error | R5.4 |

### 6.2 Integration-test database

**Primary path: Testcontainers (`Testcontainers.MsSql`).** This needs Docker with Linux containers.
- One SQL Server container per test run, started by an xUnit collection fixture.
- `Database.MigrateAsync()` runs, then the shared seeding logic inserts about 300 deterministic rows.
- The tests run through `WebApplicationFactory<Program>`.
- All integration tests belong to one collection, so they run sequentially on the shared database.
- Tests that change data create their own rows through a fixture helper and assert only on those rows. IT-7 asserts the change in counts, not absolute totals. This avoids a database-reset library.

**Alternative, kept for a real constraint:** the reviewers' machines are unknown, and Docker Desktop is not always available on Windows. If `TEST_SQL_CONNECTION` is set (SQL Server Express or LocalDB), the fixture creates `RequestManagement_Tests_<guid>` and drops it afterwards. This is one branch in the fixture; the tests themselves are identical.

The EF InMemory provider and SQLite are not used (D11).

---

## 7. Work Breakdown

Tasks T-001, T-002, T-003, T-101 and T-102 are **In Progress** (code written, verification items remaining), and so is T-405. T-103, T-104, T-201, T-202, T-203, T-204, T-205, T-206, T-207, T-208, T-301, T-303, T-304 and T-404 are **Done**. Every other task is **Planned**. Each task block lists its description, deliverable, related requirements, dependencies, estimate, acceptance criteria and verification method.

### Phase 0: Foundation (3.0 h)

**T-001: Verify the toolchain and pin versions.**
- Estimate: 0.5 h · Status: In Progress (code written 2026-10-20; verified locally 2026-10-21: build, 51 unit and 8 integration tests pass, no vulnerable packages; remaining: Docker with Linux containers confirmed via Testcontainers; version table and pins still to be recorded)
- **Description:** On the Windows host, run `dotnet --list-sdks`, `node -v`, `npm -v`, `ng version` and `docker version`. Confirm Linux-container mode. Decide on an ASCII work path (F3).
- **Deliverable:** A version table for the README, `global.json`, `.nvmrc`, and a recorded answer on Docker availability, which selects the default dev/test database path (D11).
- **Requirements:** R11.2. Resolves A12.
- **Depends on:** none.
- **Acceptance criteria:** Every tool reports a version, or is installed. Versions are pinned.
- **Verification:** Command output saved to the README draft.

**T-002: Repository and solution scaffold.**
- Estimate: 1.5 h · Status: In Progress (code written 2026-10-20; verified locally 2026-10-21: build, 51 unit and 8 integration tests pass, no vulnerable packages; first commit `37c3e5a` exists on `origin/main`; remaining: 0-warnings check and `dotnet format --verify-no-changes` still pending)
- **Description:**
  - `git init` and the GitHub remote.
  - `.gitignore`, `.editorconfig`, and `Directory.Build.props` (nullable on, warnings as errors).
  - `.config/dotnet-tools.json` with `dotnet-ef`.
  - The projects and references from §4.1.
  - Commit this plan.
- **Deliverable:** A solution that builds, and the first commit.
- **Requirements:** R10.1, RS.1.
- **Depends on:** T-001.
- **Acceptance criteria:** `dotnet build` produces 0 warnings. `dotnet format --verify-no-changes` passes.
- **Verification:** The build and format output.

**T-003: Local database environment.**
- Estimate: 1.0 h · Status: In Progress (code written 2026-10-20; verified locally 2026-10-21: build, 51 unit and 8 integration tests pass, no vulnerable packages; remaining: SQL Server 2022 container works via Testcontainers; `docker-compose.yml` health check and `sqlcmd` connection test still pending)
- **Description:** `docker-compose.yml` with SQL Server 2022, a health check and a volume, plus `.env.example`. The connection string comes from user-secrets or an environment variable. The non-Docker connection string (SQL Express or LocalDB) is documented.
- **Deliverable:** A working database.
- **Requirements:** R0.4, RS.2.
- **Depends on:** T-001.
- **Acceptance criteria:** The database is reachable on whichever path T-001 selected. No secrets are committed.
- **Verification:** A connection test with `sqlcmd` or SSMS.

### Phase 1: Data design and seeding (7.0 h)

**T-101: Data model and index design (non-coding).**
- Estimate: 1.5 h · Status: In Progress (code written 2026-10-20; verified locally 2026-10-21: build, 51 unit and 8 integration tests pass, no vulnerable packages; remaining: model and index tests pass; review against §5.1 still pending)
- **Description:** Finalise §4.3. Map every filter, sort and aggregation to an index, or explicitly accept a scan. Confirm A1, A3 and A5–A7.
- **Deliverable:** An updated §4.3 and the index rationale draft for `PERFORMANCE.md`.
- **Requirements:** R0.2, R1.10, R6.3, R9.6.
- **Depends on:** T-002.
- **Acceptance criteria:** Every scenario in §5.1 has an intended index or an accepted scan.
- **Verification:** Review against §2 and §5.1.

**T-102: Domain model and transition policy.**
- Estimate: 1.0 h · Status: In Progress (code written 2026-10-20; verified locally 2026-10-21: build, 51 unit and 8 integration tests pass, no vulnerable packages; remaining: UT-1 passes; review of the policy as the single source of rules still pending)
- **Description:** Entities, enums and `StatusTransitionPolicy` (A1) in `Core`.
- **Deliverable:** The `Core` types.
- **Requirements:** R0.2, R2.2.
- **Depends on:** T-101.
- **Acceptance criteria:** The policy is a pure class and is the single source of transition rules.
- **Verification:** UT-1.

**T-103: EF Core mapping and migrations.**
- Estimate: 2.0 h · Status: Done (evidence: 2026-10-22 local run on SQL Server 2022 (Docker) against an isolated database `RequestManagement_MigrationCheck`; the target was confirmed with `dotnet ef dbcontext info` before it was created, and `RequestManagement` and `RequestManagement_SeedCheck` were not modified. Steps, each exit 0: (1) `dotnet ef database update InitialCreate` created the database, history holds only `InitialCreate`; (2) `dotnet ef database update` applied `AddQueryIndexes`; (3) `dotnet ef database update InitialCreate` reverted it, the five `Requests` query indexes were gone and tables, PKs, FK, six CHECK constraints and the history index were intact; (4) `dotnet ef database update` re-applied it. Schema inspection via `sys.*` matched the mapping at every stage: 9 `Requests` columns and 6 `RequestStatusHistory` columns with the expected types (`tinyint`, `datetime2(3)`, `rowversion`, `nvarchar` lengths), FK `NO_ACTION`, and the five indexes with the planned key order, sort direction and `INCLUDE (Priority)`. `dotnet ef migrations has-pending-model-changes`: no changes. `AppDbContextModelTests`: 7 of 7 passed. No code or migrations changed. The test database is kept.)
- **Description:** `AppDbContext` and the entity configurations: `tinyint` conversions, CHECK constraints, column lengths, `IsRowVersion()`, and the foreign key. Two migrations: `InitialCreate` and `AddQueryIndexes` (D14).
- **Deliverable:** Both migrations.
- **Requirements:** R0.2, R0.4, R6.3.
- **Depends on:** T-102, T-003.
- **Acceptance criteria:** Both migrations apply to an empty database, and `InitialCreate` can be reached again by migrating down.
- **Verification:** `dotnet ef database update` in both directions, then a schema inspection.

**T-104: Deterministic seeder.**
- Estimate: 2.5 h · Status: Done (evidence: 2026-10-22 local run on a scratch database `RequestManagement_SeedCheck` (SQL Server 2022 in Docker, Release build, `Seeder --reset --count 100000`, default seed 20261020); not yet committed. Run 1: exit 0, 100,000 rows, checksum `-1953119262`, insert 6.7 s, total process 9.4 s. Run 2: exit 0, 100,000 rows, checksum `-1953119262`, insert 6.5 s, total process 9.7 s. An independent `COUNT(*)` after each run returned 100,000, and the two status and priority distributions were identical. 27 seeder unit tests (`SeedDataGenerator`, `SeederArguments`) passed in this session. The seeder integration tests (`DatabaseSeederTests`) were not re-run in this session because a running `RequestManagement.Api` process locked the build output; they are covered by the earlier integration runs recorded for T-205 to T-208. Run times are from a single pair of runs on one machine and are not a benchmark.)
- **Description:** Seeding logic in `Infrastructure` (D10). A `Seeder` console with `--count` (default 100,000) and `--reset`.
- **Deliverable:** The seeder.
- **Requirements:** R0.3, R0.5.
- **Depends on:** T-103.
- **Acceptance criteria:** Two `--reset` runs produce identical checksums. `COUNT(*)` ≥ 100,000. Run time is recorded.
- **Verification:** The checksum output from the two runs.

### Phase 2: Backend API (17.0 h)

**T-201: API foundation.**
- Estimate: 2.0 h · Status: Done (evidence: 2026-10-22 local runs (Debug builds from a separate artifacts path). Code committed in `f28d1ea`; the regression tests in `ApiFoundationTests.cs` are not yet committed. **Run, automated (`ApiFoundationTests`, 6 tests, in-process, no database):** an unhandled exception returns 500 `application/problem+json` with `status`, `title` and `traceId` and without the exception message, type name, "stackTrace" or a source location, and the exception is logged at Error on the server (QC-6, QC-8); a client abort mid-request logs nothing at Warning or above and is handled by ASP.NET Core's exception-handler middleware ("The request was aborted by the client", status 499), **not** by `GlobalExceptionHandler`, whose cancellation branch is therefore unreachable in practice (kept as is, not removed); `/openapi/v1.json` and `/swagger/index.html` return 200 in Development and 404 in Production and Staging (D13); in Development a singleton that depends on the scoped `AppDbContext` stops the app from starting ("Cannot consume scoped service"), while the same registration starts in Production, so the default scope and build validation are active in Development (QC-4). The 500, Swagger and DI-validation tests each failed when the behaviour they check was deliberately broken (error detail added to the response, Swagger enabled in every environment, scope and build validation switched off); the sources were then restored from byte copies. The client-abort test was not checked this way. **Run, manual, earlier the same day:** the API started in Development with no errors, and the same 500 body was observed over HTTP from a Kestrel process. The full integration suite (131 tests) also starts the app in Development without errors. **Covered by existing tests:** enum strings, `TimeProvider` use and the `ChangedBy` helper (`ChangedByTests`, status and bulk API tests). **Review only:** logging configuration (`appsettings*.json`), the DI registrations in `Program.cs`. Lifetimes match §4.1 except that §4.1 lists an `IMemoryCache` singleton, which the code does not register or use (T-208 uses the custom `RequestSummaryCache` singleton); §4.1 was not changed. **Not done:** Swagger UI "try it out" calls were not made (only the page and the OpenAPI JSON were fetched); the project owner accepted `Done` without them.)
- **Description:**
  - `AddProblemDetails` and an `IExceptionHandler`: 500 without internals; a cancelled client request is not logged as an error.
  - Logging configuration.
  - The OpenAPI document with Swagger UI in Development (D13).
  - `JsonStringEnumConverter`.
  - `TimeProvider`.
  - A helper that reads `ChangedBy` from the request header (A2).
  - DI registrations matching §4.1.
- **Deliverable:** A runnable API skeleton.
- **Requirements:** R0.1, R10.4, R10.6, R10.8.
- **Depends on:** T-103.
- **Acceptance criteria:** The app starts in Development, with the default DI scope and build validation, without errors. Exceptions return ProblemDetails.
- **Verification:** Startup check; manual calls through Swagger UI.

**T-202: Request search endpoint.**
- Estimate: 4.0 h · Status: Done (evidence: 2026-10-22 local run. Endpoint code committed in `f28d1ea`; the count-query test (`RequestQueryServiceTests.CountQuery_IsSelectCountOverTheSameWhereAsThePage`) is not yet committed. That test runs the real `SearchAsync`, captures the command EF executes for the count, and asserts that it starts with `SELECT COUNT(*)`, has no `ORDER BY` or `OFFSET`, and has a `WHERE` identical to the page query's; with the count changed to ignore the filters it fails, and the change was reverted. `RequestQueryServiceTests` 11 passed in three consecutive runs (WHERE, ORDER BY with `Id` tie-breaker, OFFSET/FETCH and COUNT). UT-2 (`RequestSearchQueryValidationTests`) passed. IT-1 (`RequestSearchApiTests`, 39 tests, Testcontainers SQL Server 2022, 2,505 rows, results compared with a LINQ-to-objects oracle) passed, including 400 with an error per field. Full run from a separate artifacts path: build 0 warnings, `dotnet format --verify-no-changes` clean, unit tests 165 passed, integration tests 131 passed (125 plus the 6 T-201 tests), 0 failed. "Nothing is materialised before paging" is shown by the code (the query stays `IQueryable` until the projected `ToListAsync`) and the SQL shape; no test asserts it directly. `ct` forwarding (R1.8) is review-only (QC-5): no async call in the search path lacks `ct`. The SQL files in `docs/perf/sql/` are captured in T-501.)
- **Description:** The query DTO with validation (§4.2) and a composed `IQueryable`:
  - `AsNoTracking`.
  - Filters (A6, A7) and the escaped `LIKE` search (A5).
  - A sort switch over the whitelisted fields, with `Id` as the tie-breaker.
  - `Skip`/`Take`, plus `CountAsync` over the same predicate.
  - A `Select` projection to `RequestDto`.
  - `ct` forwarded to every async call.
- **Deliverable:** `GET /api/requests`.
- **Requirements:** R1.1–R1.5, R1.7–R1.9, R6.5.
- **Depends on:** T-201.
- **Acceptance criteria:** The captured SQL contains WHERE, ORDER BY, OFFSET/FETCH and COUNT. Nothing is materialised before paging. Invalid parameters return 400 with an error per field.
- **Verification:** `ToQueryString()` capture, UT-2, IT-1.

**T-203: Get request by ID.**
- Estimate: 0.5 h · Status: Done (evidence: 2026-10-23 local run, Debug build from a separate artifacts path. Endpoint code committed in `f28d1ea`. **Run:** the 5 `RequestSearchApiTests.GetById_*` tests passed (`GetById_ReturnsTheRequest` compares the JSON with the database row; `GetById_UnknownId_Returns404ProblemDetails` for ids `999999`, `0` and `-3` checks 404, `application/problem+json` and body status 404; `GetById_NonNumericId_Returns404` checks the status code only), and 74 related API tests passed (`RequestSearchApiTests`, `RequestSummaryApiTests`, `RequestStatusApiTests`, `RequestHistoryApiTests`), including the `/summary` and `/{id}/history` routes next to `/{id}` and the IT-5 cases for `PATCH`. **Review only:** `RequestQueryService.GetByIdAsync` uses `AsNoTracking`, a `Where`, the `RequestRow` projection and `SingleOrDefaultAsync(ct)`, then maps to `RequestDto`; `RequestsController.GetById` returns `ActionResult<RequestDto>` and does not use the domain namespace (QC-3, R1.9). **Note:** the named verification IT-5 covers the 404/422/400 cases of the status update; the `GET` 200/404 tests are the `GetById_*` tests above. **Not verified:** the `Content-Type` of the 200 response and of the non-numeric-id 404 (status code only); an id larger than `int.MaxValue` (expected 404 from the `{id:int}` route constraint, no test); there is no test of the SQL shape of this query (the plan does not require one).)
- **Description:** A projection to `RequestDto`. A missing request returns 404.
- **Deliverable:** `GET /api/requests/{id}`.
- **Requirements:** R1.9, R2.1.
- **Depends on:** T-202.
- **Acceptance criteria:** Returns 200 or 404 as appropriate.
- **Verification:** IT-5.

**T-204: Summary aggregations.**
- Estimate: 1.5 h · Status: Done (evidence: 2026-10-22 local run, committed in `f28d1ea` and `3438905` (endpoint and tests) and `459a1e6` (IT-7 part). `RequestSummaryApiTests` compares the endpoint with independent hand-written GROUP BY SQL on a known distribution and checks that both lists add up to the total; `RequestSummaryTests` asserts the two GROUP BY queries and the zero-filled, enum-ordered shape; the "fresh after an update" part of IT-7 is covered by `RequestSummaryCacheApiTests` (T-208). Same full run as T-208: unit tests 164 passed, integration tests 125 passed.)
- **Description:** Two server-side GROUP BY queries (Status, Priority) plus the total (A4).
- **Deliverable:** `GET /api/requests/summary`.
- **Requirements:** R1.6.
- **Depends on:** T-202.
- **Acceptance criteria:** The counts add up to the total and match direct SQL.
- **Verification:** A SQL cross-check, IT-7.

**T-205: Single status update with concurrency and audit.**
- Estimate: 3.0 h · Status: Done (evidence: 2026-10-22 local run, committed as `1596f61`. `dotnet build` 0 warnings, `dotnet format --verify-no-changes` clean; unit tests 124 passed, integration tests 75 passed (Testcontainers, SQL Server 2022), 0 failed. Files: `RequestStatusService.cs`, `RequestsController.UpdateStatus`, `RequestStatusApiTests.cs` (IT-2 to IT-5 and the atomicity tests), `UpdateStatusRequestTests.cs`. Not part of this task: the cache invalidation call is added in T-208.)
- **Description:** The flow in §4.4. A result type is mapped to 200/404/409/422 (D7). The per-item logic is written so that T-207 reuses it (`RequestStatusService.ApplyAsync` takes an already loaded request).
- **Deliverable:** `PATCH /api/requests/{id}/status`.
- **Requirements:** R2.1–R2.5, R3.1, R10.5.
- **Depends on:** T-203.
- **Acceptance criteria:** A stale version never overwrites newer data. `UpdatedAt`, `RowVersion` and the history row change together or not at all.
- **Verification:** IT-2 to IT-5.

**T-206: History endpoint.**
- Estimate: 1.0 h · Status: Done (evidence: 2026-10-22 local run, committed as `5b8be69`. `dotnet build` 0 warnings, `dotnet format --verify-no-changes` clean; unit tests 127 passed, integration tests 82 passed, 0 failed. Files: `RequestQueryService.GetHistoryAsync`, `RequestsController.GetHistory`, `StatusHistoryEntryDto.cs`, `RequestHistoryApiTests.cs` (IT-8), `RequestHistoryQueryTests.cs`.)
- **Description:** Returns the history newest first (`ChangedAt` descending, the newest `Id` first when timestamps are equal). A missing request returns 404 ProblemDetails; a request without changes returns 200 and `[]`.
- **Deliverable:** `GET /api/requests/{id}/history`.
- **Requirements:** R3.2.
- **Depends on:** T-205.
- **Acceptance criteria:** Fields and ordering are correct.
- **Verification:** IT-8.

**T-207: Bulk status update (Partial Success).**
- Estimate: 3.0 h · Status: Done (evidence: 2026-10-22 local run, committed as `95d8698`. `dotnet build` 0 warnings, `dotnet format --verify-no-changes` clean; unit tests 151 passed, integration tests 116 passed (Testcontainers, SQL Server 2022), 0 failed. Files: `RequestStatusService.BulkUpdateStatusAsync` (reuses the private `ApplyAsync` of T-205), `RequestsController.BulkUpdateStatus`, `BulkStatusUpdateRequest.cs`, `BulkStatusUpdateResultDto.cs`, `RequestBulkStatusApiTests.cs` (IT-6), `BulkStatusUpdateRequestTests.cs` (UT-3). Contract: a valid call always returns 200 with `requested`, `succeeded`, `failed` and one result per item in the order sent; `rowVersion` is the new version after `Updated` and the current version after `Conflict`; an invalid envelope returns 400 and changes nothing. Not part of this task: the cache invalidation call is added in T-208; the README documentation of the contract is T-602.)
- **Description:** The bulk flow in §4.4 (D2, A9), reusing the per-item logic from T-205.
- **Deliverable:** `POST /api/requests/bulk-status`.
- **Requirements:** R4.1–R4.3, R10.2.
- **Depends on:** T-205.
- **Acceptance criteria:** A mixed batch returns the correct outcomes, and only the valid rows change.
- **Verification:** UT-3, IT-6.

**T-208: Summary cache and invalidation.**
- Estimate: 2.0 h · Status: Done (evidence: 2026-10-22 local run, committed as `459a1e6`. `dotnet build` 0 warnings, `dotnet format --verify-no-changes` clean; unit tests 164 passed, integration tests 125 passed (Testcontainers, SQL Server 2022), 0 failed. Files: `RequestSummaryCache.cs`, `SummaryCacheOptions.cs`, `RequestQueryService.GetSummaryAsync`, `RequestStatusService` (invalidation after the commit in the single update and, once in a `finally`, in the bulk update), `Program.cs` and `appsettings.json` (`SummaryCache:Enabled`, `SummaryCache:ExpirationSeconds`, validated at startup), `RequestSummaryCacheTests.cs` (UT-4), `RequestSummaryCacheApiTests.cs` (IT-7). The "cache hit issues no SQL" criterion is measured with an EF Core command-counting interceptor (0 commands on a hit, 2 on a miss), not with the Development SQL log, which was not run. The generation guard is covered by a unit test and by a forced interleaving against SQL Server; both fail when the guard is removed, and the IT-7 tests fail when the invalidation calls are removed. Not part of this task: README documentation of the reasoning and the scale-out description (R7.4, R7.5: T-602), and the B2 measurement.)
- **Description:** `RequestSummaryCache` (§4.5), with its two configuration keys. Invalidation is called from the code paths of T-205 and T-207 after commit.
- **Deliverable:** A cached summary.
- **Requirements:** R7.1–R7.3.
- **Depends on:** T-204, T-205, T-207.
- **Acceptance criteria:** A cache hit issues no SQL. The summary is fresh immediately after an update.
- **Verification:** UT-4, IT-7, and the SQL log in Development.

### Phase 3: Angular (13.5 h)

**T-301: Angular scaffold and error handling.**
- Estimate: 1.5 h · Status: Done (evidence: 2026-10-25 local run, not yet committed. Angular 21.2 and Angular Material 21.2 on Node 22.22.0; Angular 22 was not used because it requires Node 22.22.3 or later. `npm run build` succeeded and `ng test` passed (5 tests: app shell, `httpErrorInterceptor`), both run directly in the non-ASCII repository path, so no ASCII work path was needed. `ng serve` returned the shell with HTTP 200, and `/api/requests?page=1&status=New` on port 4200 reached a stub on `localhost:5080` with its path, query string and 409 ProblemDetails body intact. The real backend was not running, so the proxy was not exercised against the API, and the shell was not viewed in a browser. Files: `frontend/` (`proxy.conf.json`, `angular.json` serve option, `app.config.ts`, `app.ts`, `app.html`, `core/api-error.ts`, `core/http-error.interceptor.ts` and its spec). `npm audit` reports 2 vulnerabilities (`undici`, via `@angular/build`, dev tooling only), and the only fix offered is a downgrade to Angular 20.)
- **Description:** A standalone app with routing, Angular Material (D9), the `/api` dev proxy, `httpErrorInterceptor` and `ApiError`.
- **Deliverable:** A running `frontend/` app.
- **Requirements:** R5.8.
- **Depends on:** T-002. Can run in parallel with Phase 2, because the contract is fixed in §4.2.
- **Acceptance criteria:** `ng serve` shows the app shell, and `/api` calls are proxied.
- **Verification:** Manual check.

**T-302: Typed models and API service.**
- Estimate: 1.0 h · Status: Done (evidence: 2026-10-25 local run, not yet committed. New files in `frontend/src/app/requests/`: `request.models.ts` (string-literal unions for status, priority, sort field and outcome; interfaces for `RequestDto`, `PagedResult`, history entry, summary, update and bulk bodies, bulk result, search params and 409 conflict details), `requests-api.service.ts` (`RequestsApiService` with `search`, `getSummary`, `getById`, `getHistory`, `updateStatus`, `bulkUpdateStatus`, plus the helpers `toHttpParams` and `readConflictDetails`) and `requests-api.service.spec.ts`. Field names, routes, string enums, the repeated `status`/`priority` query parameters and the `X-User-Name` header were checked against `RequestsController` and the `Core` DTOs. `ng test --watch=false`: 3 files, 19 tests passed (14 new: one per endpoint with method, URL, body and headers, the 409 mapped to `ApiError` and to typed details, and the query mapping); `ng build` succeeded under `strict`. A search of `src/app/requests` found no `any`, and `HttpClient` is injected only in `RequestsApiService` (plus `provideHttpClient` in `app.config.ts`). The tests use `HttpTestingController` with canned responses, not the running API, so the contract is matched by reading the backend code, not by a live call. QC-1 is a review of the files above.)
- **Description:** TypeScript interfaces matching §4.2, and `RequestsApiService` covering all 6 endpoints.
- **Deliverable:** The models and the service.
- **Requirements:** R5.8, R1.9.
- **Depends on:** T-301.
- **Acceptance criteria:** No `any` types. No component injects `HttpClient`.
- **Verification:** A strict TypeScript build and QC-1.

**T-303: List facade (debounce, switchMap, UI states).**
- Estimate: 2.5 h · Status: Done (evidence: 2026-10-25 local run, not yet committed. New files in `frontend/src/app/requests/`: `requests-list.facade.ts` (`RequestsListFacade`, provided by the page, not in root) and `requests-list.facade.spec.ts`. The search text goes through `debounceTime(300)` and `distinctUntilChanged`; filter, sort and page changes apply immediately, and a filter or page-size change resets to page 1. Every query goes through `switchMap(api.search)`, and the facade exposes the signals `state` (`loading` / `loaded` / `error`, `data`, `error`), `loading`, `error`, `data`, `items`, `empty` and `query`, plus `setSearch`, `setFilters`, `setSort`, `setPage` and `refresh` (the retry action). A newer query keeps the last page visible while loading, and an error clears it. `ng test --watch=false`: 4 files, 26 tests passed (7 new, using `HttpTestingController` and fake timers: one request per typing pause, `req.cancelled` on a superseded request, a filter change sends the new params with page 1, sort and page params, loading → loaded, loading → empty, loading → error and retry). `ng build` succeeded under `strict`. The new files contain no `any`, and `HttpClient` is not injected outside `RequestsApiService`. The summary is not part of this facade, because the plan assigns it to T-305. The facade is not yet used by any component, so it was not exercised in a browser or against the real API.)
- **Description:** `RequestsListFacade` as described in §4.7.
- **Deliverable:** The facade.
- **Requirements:** R5.1–R5.4.
- **Depends on:** T-302.
- **Acceptance criteria:** One HTTP call per typing pause. A superseded call is cancelled. The state transitions are correct.
- **Verification:** FE-1, FE-3.

**T-304: Request list UI.**
- Estimate: 3.5 h · Status: Done (evidence: 2026-10-25 local run, not yet committed. T-202 is Done, so the contract was read from `RequestSearchQuery.cs` and `toHttpParams`. New files in `frontend/src/app/requests/`: `requests-list.page.ts`, `.html`, `.scss` and `requests-list.page.spec.ts`; the empty route in `app.routes.ts` now lazy-loads the page. `RequestsListPage` provides `RequestsListFacade` itself and injects no `HttpClient`. It has the search box (debounced by the facade; one character is never sent, because the API answers 400), filters for status, priority, organization (starts with), assigned to (exact) and created from/to (the end date is inclusive, sent as the start of the next day because the API bound is exclusive), and a date-range check. The table has `matSort` on the five whitelisted fields (`title`, `status`, `priority`, `createdAt`, `updatedAt`) with the server default `createdAt` descending, and `mat-paginator` with page sizes 10, 20, 50, 100. It shows loading (progress bar, previous rows kept), empty, and error with title, detail and Retry (`facade.refresh()`). Nothing is sorted or filtered client-side. `ng test --watch=false`: 5 files, 35 tests passed (9 new: rows, loading, empty, error and retry, sort params, next page, filter params from page 1, invalid date range, debounced search without a single character, label helper). `ng build` succeeded; the list page is a 377 kB lazy chunk. Not done here: the page was not opened in a browser and was not run against the real API. Smoke checks S-1 to S-3 belong to T-604.)
- **Description:** The filters, the table with server-side sorting, the paginator, and the loading/empty/error-with-retry states.
- **Deliverable:** The list page.
- **Requirements:** R5.1, R5.4, R5.8.
- **Depends on:** T-303, T-202.
- **Acceptance criteria:** Every interaction triggers a server request. No data is sorted or filtered client-side.
- **Verification:** Smoke checks S-1 to S-3 (T-604).

**T-305: Summary panel.**
- Estimate: 1.0 h · Status: Planned
- **Description:** Shows the counts by status and by priority. Refreshes after a successful update.
- **Deliverable:** `SummaryPanelComponent`.
- **Requirements:** R5.6.
- **Depends on:** T-302, T-204.
- **Acceptance criteria:** The values match the API.
- **Verification:** S-5.

**T-306: Status update and conflict handling.**
- Estimate: 2.5 h · Status: Planned
- **Description:** A status control limited to `allowedNextStatuses`, with handling for 409 (message and reload, no retry), 422, 400 and 404.
- **Deliverable:** `StatusChangeComponent`.
- **Requirements:** R5.5.
- **Depends on:** T-304, T-205.
- **Acceptance criteria:** A conflict forced from two browser tabs shows the message, and the row then shows fresh data.
- **Verification:** FE-2, S-4.

**T-307: History view.**
- Estimate: 1.5 h · Status: Planned
- **Description:** A dialog with loading, empty and error states.
- **Deliverable:** `RequestHistoryDialogComponent`.
- **Requirements:** R5.7, R5.4.
- **Depends on:** T-302, T-206.
- **Acceptance criteria:** The dialog shows the entries created by updates.
- **Verification:** S-6.

### Phase 4: Automated tests (12.5 h)

These tasks are interleaved with Phase 2. T-401 starts right after T-202.

**T-401: Integration-test fixture.**
- Estimate: 2.5 h · Status: Planned
- **Description:** The setup in §6.2: a Testcontainers fixture, `WebApplicationFactory`, the small seed, a helper for tests to create their own rows, and the `TEST_SQL_CONNECTION` branch.
- **Deliverable:** The fixture.
- **Requirements:** R8.5, R9.6.
- **Depends on:** T-104, T-202.
- **Acceptance criteria:** A smoke test passes against real SQL Server through the primary path. The alternative path is exercised once if the environment allows.
- **Verification:** `dotnet test` output.

**T-402: Unit tests UT-1 to UT-4.**
- Estimate: 2.0 h · Status: Planned
- **Requirements:** R8.1, R8.3, R2.2, R7.1–R7.3.
- **Depends on:** T-102, T-202, T-207, T-208.
- **Acceptance criteria:** The tests pass, and each one fails when its rule is temporarily broken (spot check).
- **Verification:** `dotnet test`.

**T-403: Integration test IT-1.**
- Estimate: 1.5 h · Status: Planned
- **Requirements:** R8.2, R8.3, R8.5, R1.2–R1.5.
- **Depends on:** T-401.
- **Acceptance criteria:** The test passes.
- **Verification:** `dotnet test`.

**T-404: Integration tests IT-2 to IT-5.**
- Estimate: 2.5 h · Status: Done (evidence: 2026-10-22 local run, committed as `1596f61`. `RequestStatusApiTests.cs`: all 25 tests pass in the full integration run (75 passed, 0 failed). IT-4 (`TwoParallelUpdatesWithTheSameVersion_*`) passed 20 of 20 consecutive separate `dotnet test` runs on the final code.)
- **Requirements:** R8.4, R2.1–R2.5, R3.1, R10.6.
- **Depends on:** T-401, T-205.
- **Acceptance criteria:** All tests pass. IT-4 passes 20 consecutive runs.
- **Verification:** `dotnet test`, then a loop of 20 runs.

**T-405: Integration tests IT-6 to IT-8.**
- Estimate: 2.0 h · Status: In Progress (IT-8 is implemented and passes as `RequestHistoryApiTests`, see T-206; IT-6 is implemented and passes as `RequestBulkStatusApiTests`, see T-207; IT-7 is implemented and passes as `RequestSummaryCacheApiTests`, see T-208. All three are implemented and pass; the status is left for review because T-401 has not been re-verified)
- **Depends on:** T-401, T-206, T-207, T-208.
- **Acceptance criteria:** All tests pass.
- **Verification:** `dotnet test`.

**T-406: Angular tests FE-1 to FE-3.**
- Estimate: 2.0 h · Status: Planned
- **Requirements:** R5.1–R5.5.
- **Depends on:** T-303, T-306.
- **Acceptance criteria:** All tests pass.
- **Verification:** `ng test` output.

### Phase 5: Performance (5.5 h)

**T-501: Measurement assets and baseline.**
- Estimate: 2.0 h · Status: Planned
- **Description:**
  - Capture the SQL for B1a to B1d and B2 into `docs/perf/sql/`, recording the commit hash.
  - Write `run-sql.ps1` and `measure-api.ps1`.
  - Run steps 1 to 4 of §5.2 (the "before" phase).
- **Deliverable:** The scripts and `results/before/`, `dataset.txt` and `environment.txt`.
- **Requirements:** R6.1, R6.2, R0.3.
- **Depends on:** T-104, T-202, T-204, T-208.
- **Acceptance criteria:** Every scenario has saved stats files, plans and an API CSV.
- **Verification:** The file listing.

**T-502: Index tuning and the "after" measurement.**
- Estimate: 2.0 h · Status: Planned
- **Description:** Run step 5 of §5.2. Apply the comparison rules in §5.4, and adjust `AddQueryIndexes` (dropping indexes that don't help), re-measuring after each change.
- **Deliverable:** The final `AddQueryIndexes` migration and `results/after/`.
- **Requirements:** R6.1–R6.5.
- **Depends on:** T-501.
- **Acceptance criteria:** Each remaining index is justified under §5.4. Row counts are identical between the phases.
- **Verification:** A diff of the before and after files.

**T-503: Performance report.**
- Estimate: 1.5 h · Status: Planned
- **Description:** Write `docs/PERFORMANCE.md`:
  - the scenarios and the environment;
  - before/after tables built only from the saved artifacts;
  - plan observations and the index rationale;
  - the hypotheses H1 to H4, each confirmed or refuted, with improvements;
  - how full in-memory loading is avoided.
- **Deliverable:** The report.
- **Requirements:** R1.10, R6.1–R6.5, R11.4.
- **Depends on:** T-502.
- **Acceptance criteria:** Every number links to a file in `results/`.
- **Verification:** Cross-check each number against its source file.

### Phase 6: Documentation, review and submission (7.5 h)

**T-601: README: run, versions and structure.**
- Estimate: 2.0 h · Status: Planned
- **Description:**
  - Prerequisites, including both database paths.
  - Step-by-step instructions: compose, seed, API, UI, tests.
  - The version table, the solution structure and the endpoint list.
  - The Swagger UI link.
  - A list of dependencies, each with the reason it is needed.
- **Deliverable:** `README.md`.
- **Requirements:** R11.1–R11.3, RS.2, R10.9.
- **Depends on:** T-208, T-307, T-406.
- **Acceptance criteria:** A reviewer can run the whole system using only the README.
- **Verification:** T-604.

**T-602: Design documentation.**
- Estimate: 2.0 h · Status: Planned
- **Description:** README sections covering:
  - the database and indexes (D1, linking to `PERFORMANCE.md`);
  - concurrency and bulk behaviour, with sample request and response bodies;
  - the cache, its invalidation and scale-out (D3);
  - two decisions with their alternatives (D1, D2);
  - the assumptions from §3.2;
  - one limitation (contains search is not index-backed) and one improvement (full-text search or keyset pagination);
  - AI usage, maintained as a running log of which parts were AI-assisted (including this plan) and what was verified or changed by hand.
- **Deliverable:** The README sections.
- **Requirements:** R11.4–R11.9, R4.2, R4.3, R7.4, R7.5, RS.4.
- **Depends on:** T-503.
- **Acceptance criteria:** Every item from R11.4 to R11.9 is present.
- **Verification:** The §11 checklist.

**T-603: Code-quality review.**
- Estimate: 1.5 h · Status: Planned
- **Description:** Review all code, reading AI-assisted code line by line, against this checklist:

| Check | Criterion | Requirements |
|---|---|---|
| QC-1 | Project references as in §4.1, with `Core` free of EF and ASP.NET. No Angular component injects `HttpClient`. | R10.1, R5.8 |
| QC-2 | `dotnet format --verify-no-changes` and the Angular lint pass. The single and bulk updates share the per-item logic. No copy-pasted query code. | R10.2 |
| QC-3 | No entity type appears in a controller signature or response. One projection per DTO. | R10.3, R1.9 |
| QC-4 | The app starts in Development with DI scope and build validation. Lifetimes match §4.1. | R10.4 |
| QC-5 | No `.Result`, `.Wait()` or `async void`. Every async I/O call forwards `CancellationToken`. | R10.5, R1.8 |
| QC-6 | Every error response is ProblemDetails (asserted in IT-5). A 500 contains no stack trace. | R10.6 |
| QC-7 | One validation mechanism and one error shape across all endpoints. | R10.7 |
| QC-8 | Status changes, conflicts, bulk results and unhandled errors are logged. Bodies, connection strings and headers are not. | R10.8 |
| QC-9 | No item from §4.6 has been added. Every package has a listed reason. No interface has only one implementation unless it sits at the Api→Infrastructure boundary. | R10.9 |

- **Deliverable:** Fixes, plus review notes in the AI-usage section.
- **Requirements:** R10.1–R10.9, R1.8, RS.4.
- **Depends on:** T-208, T-307, T-406.
- **Acceptance criteria:** QC-1 to QC-9 all pass.
- **Verification:** The checklist with notes, committed.

**T-604: Clean-clone end-to-end verification.**
- Estimate: 1.5 h · Status: Planned
- **Description:** In a fresh clone, follow the README exactly: compose, seed 100,000 rows, start the API and the UI, run all tests, then run these smoke checks:

| Smoke check | What to confirm |
|---|---|
| S-1 | The list loads and pages through the 100,000 rows. |
| S-2 | Filters, search and sort each send a server request with the right parameters (browser Network tab). |
| S-3 | The loading, empty (a search with no matches) and error (API stopped) states each appear. |
| S-4 | A status change works. A two-tab conflict shows the 409 message, and the row reloads. |
| S-5 | The summary is shown and updates after a change. |
| S-6 | History shows the entries for a request. |
| S-7 | A mixed bulk call through Swagger UI returns the outcome for each item. |

- **Deliverable:** A verification log at `docs/verification-log.md`.
- **Requirements:** RS.1, RS.2, R11.1, R5.1, R5.4–R5.7.
- **Depends on:** T-601, T-602, T-603.
- **Acceptance criteria:** Every step and smoke check passes with no undocumented action.
- **Verification:** The committed log.

**T-605: Publish and final plan update.**
- Estimate: 0.5 h · Status: Planned
- **Description:** Push to GitHub and check reviewer access from an anonymous browser session. Update every task status in this plan with links to its evidence.
- **Deliverable:** The repository URL and the final version of this plan.
- **Requirements:** RS.1, RS.3, R9.1–R9.6.
- **Depends on:** T-604.
- **Acceptance criteria:** The link works. Every status is backed by its evidence.
- **Verification:** The anonymous access check.

### Optional (only after M5 is green; not counted in the totals)

| ID | Task | Estimate | Why it is optional |
|---|---|---|---|
| T-901 | Angular bulk selection and action, showing per-item outcomes | 2.5 h | Bulk is required only at the API level (PDF §4); the Angular section (§5) does not list it. |
| T-902 | A full `docker-compose` that also runs the API and the UI | 1.5 h | Reviewer convenience only |

---

## 8. Schedule, Milestones and Effort Reconciliation

**Critical path:**
T-001 → T-002 → T-101 → T-102 → T-103 → T-104 → T-201 → T-202 → T-203 → T-205 → T-207 → T-208 → T-501 → T-502 → T-503 → T-602 → T-604 → T-605

**Parallel work:**
- T-003 can run alongside T-002.
- T-301 and T-302 can run alongside Phase 2.
- T-401 to T-405 are written alongside the endpoints they cover.

**Dependency check:** every dependency points to an earlier task or to a task in a parallel track. There are no cycles.

| Phase | Task estimates | Total |
|---|---|---|
| P0 Foundation | 0.5 + 1.5 + 1.0 | 3.0 h |
| P1 Data | 1.5 + 1.0 + 2.0 + 2.5 | 7.0 h |
| P2 Backend | 2.0 + 4.0 + 0.5 + 1.5 + 3.0 + 1.0 + 3.0 + 2.0 | 17.0 h |
| P3 Angular | 1.5 + 1.0 + 2.5 + 3.5 + 1.0 + 2.5 + 1.5 | 13.5 h |
| P4 Tests | 2.5 + 2.0 + 1.5 + 2.5 + 2.0 + 2.0 | 12.5 h |
| P5 Performance | 2.0 + 2.0 + 1.5 | 5.5 h |
| P6 Docs and submission | 2.0 + 2.0 + 1.5 + 1.5 + 0.5 | 7.5 h |
| **Total (core)** | | **66.0 h** |

| Milestone | Exit criteria | Tasks | Effort |
|---|---|---|---|
| M1 Data foundation | Database migrated; 100,000 deterministic rows | P0 + P1 | 10.0 h |
| M2 Backend complete | 6 endpoints; UT-1 to UT-4 and IT-1 to IT-8 pass | P2 + T-401 to T-405 | 27.5 h |
| M3 Frontend complete | All R5 features; FE-1 to FE-3 pass | P3 + T-406 | 15.5 h |
| M4 Performance evidence | `PERFORMANCE.md` backed by saved artifacts | P5 | 5.5 h |
| M5 Submission ready | Clean-clone check passes; repository published | P6 | 7.5 h |
| **Total** | Matches the phase total | | **66.0 h** |

**Envelope:** 66.0 h plus about 15% contingency (≈ 10 h), giving **≈ 76 h**. The optional tasks add 4.0 h. This is an estimate, not a commitment.

**If time runs short:** cut the optional tasks first, then the extra benchmark variants B1c and B1d. Never cut a Must requirement.

---

## 9. Risks and Mitigations

| ID | Risk | Likelihood / Impact | Mitigation |
|---|---|---|---|
| R-01 | Docker is unavailable on the dev machine or a reviewer's machine. | M / H | T-001 checks the dev machine. The env-var alternative covers both development and tests (§6.2). The README documents both paths. |
| R-02 | The contains search scans the table. | H / M | Minimum search length plus selective filters. Measured in B1c (H1). Full-text search is the documented improvement. |
| R-03 | Deep offsets and the count query are slow. | M / M | Measured in B1b and B1a (H2, H3). Keyset pagination is the documented option. |
| R-04 | A race refills the cache with stale data. | M / M | The generation guard plus a short expiration. Covered by UT-4 and IT-7. |
| R-05 | Reviewers misread the bulk semantics. | M / M | Explicit per-item outcomes, README examples, IT-6. |
| R-06 | Undefined numeric enum values bind silently. | M / L | `Enum.IsDefined` validation. Covered by UT-2. |
| R-07 | The non-ASCII path with a space breaks tooling. | M / M | Use an ASCII work path (F3). |
| R-08 | The concurrency test (IT-4) is flaky. | M / M | Synchronised start; assert only that exactly one update succeeds; run 20 times. |
| R-09 | Scope creep and over-engineering. | M / M | §4.6, D4 and QC-9. Optional tasks only after M5. |
| R-10 | Version drift between machines. | M / M | `global.json`, `.nvmrc`, lock files, T-604. |
| R-11 | AI-generated code is wrong. | M / H | Line-by-line review in T-603; tests that must fail when their rule is broken; the AI-usage log. |
| R-12 | Reviewers disagree with assumptions A1 to A14. | M / L | Each is isolated in one place and documented, so changing one is a small edit. |
| R-13 | Seeding is slow or nondeterministic. | L / M | `SqlBulkCopy`, a fixed seed, the checksum check. |
| R-14 | `ChangedBy` can be spoofed (A2). | H / L | Accepted and documented as a limitation. Real authentication would replace the header. |
| R-15 | Timing results depend on the environment. | H / L | Logical reads are the primary metric. Before/after runs happen on the same machine and dataset (§5.4). |

---

## 10. Requirement Traceability Matrix

Task-level status is in §7. Requirement rows span several tasks, so none is complete yet; the parts verified on 2026-10-22 through T-201, T-202, T-204, T-205, T-207, T-208 and T-404 are the search API behaviour of R1.2 to R1.5 and R1.7 (UT-2, IT-1), the SQL shape behind R1.1 and R6.5 (the captured-SQL assertions in `RequestQueryServiceTests`; the `docs/perf/sql` files are T-501), the ProblemDetails behaviour of R10.6 (`ApiFoundationTests`, IT-5), the API-level behaviour of R1.6 (summary), R2.1 (PATCH and history), R2.2, R2.3, R2.4 and R3.1 (single and bulk update), by IT-2 to IT-6, R3.2 by IT-8, the API behaviour of R4.1 to R4.3 by UT-3 and IT-6 (the README documentation of R4.2 and R4.3 is T-602), and R7.1 to R7.3 by UT-4 and IT-7 (R7.4 and R7.5 are documentation, T-602). Pending: FE-2 and the rest of each row. Requirements covered by the in-progress tasks (T-001 to T-003, T-101, T-102 and T-405) have code but incomplete verification; the parts that depend only on tasks still **Planned** have not been started. In the Evidence column:
- *Test* means an automated test;
- *Review* means a reviewer reads the code or document and records the result;
- *Smoke* means a manual check in T-604.

| Req | Implementation (decision / assumption) | Tasks | Acceptance criterion | Evidence |
|---|---|---|---|---|
| R0.1 | Layered solution, DI, async, ProblemDetails (D4, D5) | T-002, T-201 | As described in §4.1 and §4.4 | Review: QC-1, QC-4–QC-6 |
| R0.2 | Schema in §4.3 | T-101, T-103 | All 9 fields; enum values exactly as in the PDF | Review: schema; Test: IT-2 |
| R0.3 | Seeder with 100,000 rows (D10) | T-104 | `COUNT(*)` ≥ 100,000 | `results/dataset.txt` |
| R0.4 | SQL Server 2022 (D1) | T-003, T-103 | Database runs on the selected path | T-604 log |
| R0.5 | `--reset`, deterministic (D10) | T-104 | Identical checksums across runs | Seeder output |
| R0.6 | Context; addressed through R2.3, R6.x and R7.x | n/a | n/a | No separate evidence |
| R1.1 | `IQueryable` translated to SQL; the UI only sends parameters | T-202, T-304 | Nothing materialised before paging; no client-side data operations | `perf/sql/*.sql`; Test: FE-1; Smoke: S-2 |
| R1.2 | OFFSET/FETCH plus count (D8) | T-202 | Correct page and `totalCount` | Test: IT-1 |
| R1.3 | AND-combined filters (A6, A7) | T-202 | Each filter alone and combined | Test: IT-1 |
| R1.4 | Contains search (A5) | T-202 | Matches in either field | Test: IT-1 |
| R1.5 | 5 whitelisted sort fields | T-202 | 3+ fields, asc and desc | Test: IT-1, UT-2 |
| R1.6 | Counts by Status and Priority (A4) | T-204 | Counts sum to the total | Test: IT-7; SQL cross-check |
| R1.7 | `pageSize` ≤ 100 (A8); validation | T-202 | Invalid input returns 400 per field | Test: UT-2, IT-1 |
| R1.8 | `ct` forwarded through all I/O | T-202–T-208 | Every async I/O call takes `ct` | Review only: QC-5 |
| R1.9 | `Select` projections | T-202, T-203 | No entity in any response | Review: QC-3 |
| R1.10 | `PERFORMANCE.md` section | T-101, T-503 | Explains how full loading is avoided and maps indexes to scenarios | Review of the document |
| R2.1 | 404 (D7) | T-203, T-205, T-206 | A missing ID returns 404 ProblemDetails | Test: IT-5, IT-8 |
| R2.2 | 400 for an invalid value, 422 for a disallowed transition (A1, D7) | T-102, T-205 | The message names the rejected transition | Test: UT-1, IT-5 |
| R2.3 | `rowversion` in the WHERE clause; 409 | T-205 | Exactly one of two concurrent updates succeeds | Test: IT-3, IT-4 |
| R2.4 | `UpdatedAt` and the DB-maintained `rowversion` saved in the same `SaveChanges` | T-205 | Both change on success; neither changes on failure | Test: IT-2, IT-3 |
| R2.5 | Version check on the server; no automatic retry in the UI | T-205, T-306 | A stale write never persists | Test: IT-3, IT-4, FE-2 |
| R3.1 | History row in the same transaction (A2) | T-205, T-207 | One row per success; none per failure | Test: IT-2, IT-3, IT-6 |
| R3.2 | History endpoint | T-206 | Newest first | Test: IT-8 |
| R4.1 | Bulk, 1–100 items | T-207 | 101 items returns 400 | Test: UT-3, IT-6 |
| R4.2 | NotFound / Conflict / InvalidTransition per item (A9) | T-207, T-602 | Behaviour documented with examples | Test: IT-6; Review: README |
| R4.3 | Partial Success (D2) | T-207, T-602 | Justification and the response contract documented | Review: README; Test: IT-6 |
| R5.1 | Facade sends query parameters | T-303, T-304 | Every change calls the API with parameters | Test: FE-1; Smoke: S-2 |
| R5.2 | `debounceTime(300)` | T-303 | One call per typing pause | Test: FE-1 |
| R5.3 | `switchMap` | T-303 | An in-flight request is cancelled | Test: FE-1 |
| R5.4 | State model and its rendering | T-303, T-304, T-307 | Loading, empty and error are shown | Test: FE-3; Smoke: S-3 |
| R5.5 | Status control with 409 handling | T-306 | Message and reload, no retry | Test: FE-2; Smoke: S-4 |
| R5.6 | Summary panel | T-305 | Both aggregations shown | Smoke only: S-5 |
| R5.7 | History dialog | T-307 | Entries shown | Smoke only: S-6 |
| R5.8 | API service, facade, presentational components | T-301–T-307 | No component uses `HttpClient` | Review: QC-1 |
| R6.1 | B1 and B2 on 100,000 rows (§5) | T-501, T-502 | Both measured before and after | `results/` |
| R6.2 | `STATISTICS IO/TIME`, actual plans | T-501, T-502 | Plan and logical reads saved for each scenario | `.sqlplan` and `.stats.txt` files |
| R6.3 | `AddQueryIndexes` with reasons (D14) | T-101, T-502, T-503 | Each index tied to a scenario and its measured effect | `PERFORMANCE.md` |
| R6.4 | H1–H4, each resolved | T-503 | At least one bottleneck backed by data, with an improvement | `PERFORMANCE.md` |
| R6.5 | Nothing materialised before paging | T-202 | Captured SQL contains WHERE, ORDER BY and OFFSET | `perf/sql/*.sql` |
| R7.1 | Summary cache (D3) | T-208 | A hit issues no SQL | Test: UT-4; SQL log |
| R7.2 | 60 s, configurable | T-208 | The entry expires | Test: UT-4 |
| R7.3 | Invalidate after commit, plus the generation guard | T-205, T-207, T-208 | Summary is fresh right after an update | Test: UT-4, IT-7 |
| R7.4 | Reasoning (D3) | T-602 | Documented | Review: README |
| R7.5 | Scale-out description (§4.5) | T-602 | A shared-cache option described | Review: README |
| R8.1 | 4 UT, 8 IT, 3 FE | T-401–T-406 | ≥ 4 meaningful tests, ≥ 1 integration test | Test-run output |
| R8.2 | IT-1, IT-2 | T-403, T-404 | Pass | Test-run output |
| R8.3 | UT-2, UT-3, IT-5 | T-402, T-404 | Pass | Test-run output |
| R8.4 | IT-3, IT-4 | T-404 | IT-4 passes 20 runs | Output of the 20-run loop |
| R8.5 | Testcontainers SQL Server with `WebApplicationFactory` (D11) | T-401 | Runs against real SQL Server | Test-run output |
| R9.1 | §7: 7 phases, 36 tasks | This plan; T-605 | Every requirement maps to ≥ 1 task | This matrix |
| R9.2 | Each task block has a Description and a Deliverable | §7 | True for all 36 tasks | Review of §7 |
| R9.3 | "Depends on" for each task; the §8 critical path | §7, §8 | No backward or cyclic dependencies | §8 dependency check |
| R9.4 | Estimate per task | §7, §8 | Phase and milestone sums reconcile | §8 tables |
| R9.5 | This matrix, plus a Requirements line per task | §7, §10 | Every R-ID appears in a matrix row | §12 review |
| R9.6 | Non-coding tasks: T-101 (DB design), T-401–T-406 (tests), T-501–T-503 (performance), T-601–T-602 (docs), T-003 and T-604 (run readiness) | Same | All five categories present | §7 |
| R10.1 | D4 layout and references | T-002, T-603 | QC-1 | Review |
| R10.2 | `.editorconfig`, format check, shared per-item logic | T-002, T-207, T-603 | QC-2 | `dotnet format` output; Review |
| R10.3 | DTOs in `Core`, projections | T-202, T-302, T-603 | QC-3 | Review |
| R10.4 | Lifetimes in §4.1 | T-201, T-603 | QC-4 | Startup check; Review |
| R10.5 | Async end-to-end | T-202–T-208, T-603 | QC-5 | Review |
| R10.6 | ProblemDetails and the exception handler | T-201 | QC-6 | Test: IT-5 |
| R10.7 | One validation mechanism (D5) | T-202, T-205, T-207 | QC-7 | Test: UT-2, UT-3, IT-1, IT-5 |
| R10.8 | Structured logs at the listed points | T-201, T-205, T-207 | QC-8 | Review; T-604 log sample |
| R10.9 | §4.6, the dependency list, D4 | T-601, T-603 | QC-9 | Review |
| R11.1 | README run steps | T-601 | A clean clone runs | T-604 log |
| R11.2 | Version table | T-001, T-601 | Matches the pinned files | Review |
| R11.3 | Structure section | T-601 | Matches the repository | Review |
| R11.4 | Database and indexes | T-602, T-503 | Present | Review: README, `PERFORMANCE.md` |
| R11.5 | Concurrency and bulk | T-602 | Present, with examples | Review: README |
| R11.6 | Cache and invalidation | T-602 | Present | Review: README |
| R11.7 | D1 and D2 with their alternatives | T-602 | Two decisions | Review: README |
| R11.8 | One limitation and one improvement | T-602 | Present | Review: README |
| R11.9 | AI-usage log | T-602, T-603 | Lists the parts and what was verified | Review: README |
| RS.1 | GitHub, Swagger UI (D13), docs | T-605 | Reviewers can reach everything | Anonymous access check |
| RS.2 | All components runnable | T-604 | Clean-clone run passes | T-604 log |
| RS.3 | Link-based submission | T-605 | No ZIP and no email attachment | The submission itself |
| RS.4 | Review of all AI-assisted code | T-603 | All code reviewed | QC notes; AI section |

---

## 11. Acceptance Checklist (final submission)

**Data and API**
- [ ] Migrations create the database. Seeding produces ≥ 100,000 rows with identical checksums across `--reset` runs.
- [ ] The list endpoint supports server-side paging; combined filters (Status, Priority, OrganizationName, AssignedTo, date range); search on Title and OrganizationName; and sorting on ≥ 3 fields, asc and desc.
- [ ] Page size is limited and parameters are validated (400). Only DTOs are returned. `CancellationToken` is forwarded.
- [ ] At least 2 aggregations are returned.

**Status update, concurrency and audit**
- [ ] A missing request returns 404. An invalid value returns 400. A disallowed transition returns 422.
- [ ] A competing update returns 409, and the database is unchanged.
- [ ] `UpdatedAt` and `RowVersion` change together on every successful update.
- [ ] Each status change writes a history row with RequestId, PreviousStatus, NewStatus, ChangedAt and ChangedBy. The history endpoint works.
- [ ] Bulk accepts 1–100 items, returns an outcome per item, and the Partial Success reasoning is documented.

**Cache**
- [ ] The summary is cached with an expiration, invalidated after commit, and the choice and the scale-out approach are documented.

**Angular**
- [ ] All data operations happen on the server.
- [ ] Search is debounced, and superseded requests are cancelled.
- [ ] Loading, empty and error states work.
- [ ] 409 is handled.
- [ ] Aggregations and history are shown.
- [ ] Components and services are separated.

**Performance**
- [ ] B1 and B2 are measured before and after on 100,000 rows.
- [ ] Plans and statistics files are saved.
- [ ] Indexes are justified.
- [ ] A bottleneck and an improvement are documented.
- [ ] Every number traces to a file.

**Tests**
- [ ] ≥ 4 meaningful tests, including integration tests against API + SQL Server covering the happy path, validation and concurrency conflicts.
- [ ] All tests pass from a clean clone.

**Documentation**
- [ ] R11.1–R11.9 are present.
- [ ] Assumptions A1–A14 are stated.

**Submission**
- [ ] GitHub link, accessible anonymously. No ZIP or email.
- [ ] T-604 log committed.
- [ ] All task statuses updated with evidence; any deviations explained.

---

## 12. Coverage Review

**Coverage:**
- All 77 catalogue entries in §2 have at least one task and one planned evidence item.
- R0.6 is the exception: it is context and has no separate evidence.
- This is a plan-time coverage check. No requirement is fully verified yet because each spans several tasks; the verified parts are listed in §10, and the status of every task is in §7.

**Evidence strength:**
- **Automated tests:** R1.2–R1.7, R2.x, R3.x, R4.1, R5.1–R5.5, R7.1–R7.3, R8.x, R10.6, R10.7.
- **Review only:** R1.8, R1.9, R10.1–R10.5, R10.8, R10.9.
- **Documents or artifacts:** R1.10, R4.3, R6.x, R7.4, R7.5, R9.x, R11.x and RS.x.
- **Manual smoke checks only:** R5.6 and R5.7. A cheap component test could be added if review time allows.

**Ambiguities that cannot be resolved from the PDF.** Each one has a default, but it needs confirmation from the assignment owner:
- the allowed transitions (A1);
- the source of `ChangedBy` (A2);
- the scope of the aggregations (A4);
- the search and filter match semantics (A5, A6);
- which date field the range applies to (A7);
- the page-size limit (A8);
- how bulk items carry versions (A9);
- whether seeded history is expected (A11);
- the submission channel (A13).

**Not required by the PDF, but planned as decisions:**
- the 422, 404 and 400 status choices (D7);
- PATCH as the update verb;
- Swagger UI.

---

## 13. Review Changes (v1 → v2)

1. **Traceability rebuilt per requirement.** The v1 matrix grouped R9.1–R9.6, R10.1–R10.9, R11.1–R11.3, R11.4–R11.9 and RS.1–RS.3 into single rows. There is now one row per requirement, with an acceptance criterion and an evidence type, and §12 states honestly which items rely on review or smoke checks only.
2. **Code-quality and planning mappings made concrete.** Added the QC-1 to QC-9 checklist to T-603, each item tied to one R10 requirement. Added the S-1 to S-7 smoke checks to T-604. Planning requirements R9.1 to R9.6 now map to specific sections.
3. **Assumptions separated from decisions** (§3.2 and §3.3). The transitions, `ChangedBy`, aggregation scope, search, filters, date field, page-size limit and bulk versions are now labelled assumptions. The HTTP status choices are decision D7. Only 409 is marked as required (PDF §5).
4. **Simplified:**
   - Removed `ICurrentUserProvider`; a header helper replaces it.
   - Removed the `ISummaryCache` interface; a concrete class replaces it.
   - Removed Respawn; tests create their own rows and assert deltas.
   - Removed the CORS configuration (the dev proxy makes it unnecessary).
   - Removed the optional `READ_COMMITTED_SNAPSHOT` setting, the optional bulk benchmark (B3), the lookups endpoint, and the open choices of k6 and Scalar.
   - Each remaining piece of infrastructure has a justification (D1, D3, D4, D9, D11, D13, D14).
5. **Integration-test path clarified.** Testcontainers is the primary path. The env-var alternative is kept only for the real constraint of Docker being unavailable, and it is one branch in the fixture.
6. **Performance plan made reproducible.**
   - Fixed parameters for each scenario.
   - v1's B1b asked for page 200 of a filter that yields about 30 pages; it is now an unfiltered deep page.
   - A separate `AddQueryIndexes` migration gives the before/after states.
   - Committed SQL files and scripts, defined metrics, saved artifacts and comparison rules.
   - The bottlenecks are now stated as hypotheses, not results.
7. **Corrections:**
   - T-301 now depends on T-002 rather than T-001.
   - T-208 now depends on T-207.
   - T-501 now depends on T-208 and sits on the critical path.
   - Added FE-3 for UI states (R5.4 previously had manual evidence only).
   - IT-5 now asserts ProblemDetails for R10.6.
   - The requirement count is now 77; the v1 summary said 75.
8. **Estimates re-reconciled.**
   - The core total changed from 65.5 h to 66.0 h: T-401 −0.5 h, T-406 +0.5 h, T-501 +0.5 h.
   - Phases and milestones both total 66.0 h. The envelope is ≈ 76 h.
   - Optional work dropped from 5.0 h to 4.0 h.
9. **Unchanged:** every task remains `Planned`. No implementation, tests or benchmarks exist.
