# Request Management System

Full-stack take-home: .NET backend, SQL Server, Angular frontend.
The work plan is in [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md).

> **Status:** the backend (search, summary, status update with optimistic concurrency, history,
> bulk update, summary cache), the Angular app and their automated tests are implemented. The README
> steps were checked in a clean clone, with deviations that are documented in this README and in
> [`docs/verification-log.md`](docs/verification-log.md) (a second SQL Server instance and port, the
> connection string from the environment, the Seeder guards, `--no-launch-profile`).
> The performance measurement ([`docs/perf/`](docs/perf), plan T-501 to T-503) was run once per phase
> and is reported in [`docs/perf/PERFORMANCE.md`](docs/perf/PERFORMANCE.md), **with a stated limitation**:
> in the `after` phase only 3 of 14 statements were marked plan-stable, so the before/after comparison
> is not claimed to be fully valid. The tasks T-501 to T-503 are not marked Done. This README quotes no
> performance numbers. Task status and evidence: [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md).

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| .NET SDK | 10.0.1xx or later feature band (`backend/global.json`; developed with 10.0.402) | Build, tests, EF Core tools |
| Node.js + npm | Node 22 LTS, npm 10 or later (developed with Node 22.22.0, npm 11.8.0; `.nvmrc` pins 22.22.0, `frontend/package.json` pins `npm@10.9.4`) | Angular app and its tests |
| Docker Desktop (Linux containers) | any current | Development SQL Server and the integration tests |

Without Docker: use SQL Server Express or LocalDB and put its connection string in the
steps below; for the integration tests set `TEST_SQL_CONNECTION` (see [Tests](#tests)).

Tip: keep the repository in an ASCII path without spaces (for example `C:\dev\request-management`);
the Angular tooling is sensitive to such paths (plan F3/R-07).

## Quick start

All commands are PowerShell from the repository root. Details for each step are below.

1. Database: `Copy-Item .env.example .env`, edit the password, `docker compose up -d` ([step 1](#1-start-sql-server)).
2. Connection string in user-secrets, then `dotnet ef database update` ([steps 2 to 4](#2-restore-tools-and-build)).
3. Seed 100,000 requests ([step 5](#5-seed-100000-requests)).
4. API: `dotnet run --project src/RequestManagement.Api --launch-profile http` from `backend` ([Run the API](#run-the-api)); Swagger UI at <http://localhost:5080/swagger>.
5. UI: `npm ci` then `npm start` in `frontend` ([Run the UI](#run-the-ui)); open <http://localhost:4200>.
6. Tests: [Tests](#tests).

## Solution structure

```
backend/
  RequestManagement.sln, global.json, Directory.Build.props, Directory.Packages.props
  .config/dotnet-tools.json            dotnet-ef (local tool)
  src/RequestManagement.Core           Domain, DTOs, service interfaces, StatusTransitionPolicy (no EF, no ASP.NET)
  src/RequestManagement.Infrastructure EF Core DbContext, migrations, query/status services, summary cache, seeding logic
  src/RequestManagement.Api            ASP.NET Core controllers, ProblemDetails error handling, OpenAPI + Swagger UI (Development)
  src/RequestManagement.Seeder         Console app: seed / reset the development database
  tests/RequestManagement.UnitTests    Transition rules, validation, query building, cache, generator, model mapping
  tests/RequestManagement.IntegrationTests  API + real SQL Server (Testcontainers): search, status, history, bulk, summary
frontend/                              Angular app (standalone components, Angular Material, RxJS)
  src/app/core                         HTTP error interceptor, ApiError
  src/app/requests                     Models, RequestsApiService (the only HttpClient user), list facade, page and presentational components
docs/                                  WORK_PLAN.md, verification-log.md (clean-clone check), perf/ (measurement scripts, results, PERFORMANCE.md)
docker-compose.yml                     Development SQL Server 2022
```

`Core` references neither EF Core nor ASP.NET Core. Project references:
`Api` to `Core` and `Infrastructure`; `Infrastructure` to `Core`.

## Run the database and seed data

All commands are PowerShell, starting at the repository root.

### 1. Start SQL Server

```powershell
Copy-Item .env.example .env        # then edit MSSQL_SA_PASSWORD in .env
docker compose up -d
docker compose ps                  # wait until the sqlserver service shows "healthy"
```

`docker-compose.yml` fixes the container name (`request-management-sql`); only the host port can
be changed (`MSSQL_PORT` in `.env`, default 1433). If another container already uses that name or
port (for example a second clone of this repository), either stop it first or start a separate
instance with its own project name, port and an override file that sets another `container_name`
(this is how the clean-clone check in the verification log did it):

```powershell
# docker-compose.second.yml (outside the repository):  services: { sqlserver: { container_name: rm-second-sql } }
# .env of the second clone: MSSQL_PORT=14331
docker compose -p rm-second -f docker-compose.yml -f ..\docker-compose.second.yml up -d
```

Step 7 below uses the default container name; use your own name there if you changed it.

### 2. Restore tools and build

```powershell
cd backend
dotnet tool restore
dotnet build
```

### 3. Configure the connection string (never committed)

Use the same password as in `.env`:

```powershell
$cs = "Server=localhost,1433;Database=RequestManagement;User Id=sa;Password=<your password>;TrustServerCertificate=True"

# For the seeder (stored in your user profile, outside the repository):
dotnet user-secrets set "ConnectionStrings:RequestManagement" $cs --project src/RequestManagement.Seeder

# For dotnet ef (current PowerShell session only):
$env:ConnectionStrings__RequestManagement = $cs
```

> **Shared user-secrets entry.** The Api and the Seeder projects use the same `UserSecretsId`
> (`request-management-dev`), and user-secrets live in your Windows profile, so **every clone of
> this repository on the same account reads and writes the same entry**. A clone that has no
> `ConnectionStrings__RequestManagement` variable set will use the connection string saved by another
> clone, that is, it will reach that clone's database (and `--reset` would drop it). When you work
> with more than one clone or database, do not rely on user-secrets: set
> `$env:ConnectionStrings__RequestManagement` in the shell (it takes precedence) and use the
> Seeder guards in [step 5](#5-seed-100000-requests).

### 4. Apply the migrations

```powershell
dotnet ef database update --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure
```

| Migration | Contents |
|---|---|
| `InitialCreate` | Tables, primary keys, the foreign key, CHECK constraints, the history index |
| `AddQueryIndexes` | The secondary indexes on `Requests` (kept separate for before/after measurement, decision D14) |

Other migration commands:

```powershell
# List migrations and whether each is applied
dotnet ef migrations list --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure

# Roll back to InitialCreate (removes the query indexes; used by the Phase 5 "before" measurement)
dotnet ef database update InitialCreate --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure

# Add a migration after changing the model
dotnet ef migrations add <Name> --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure --output-dir Persistence/Migrations
```

### 5. Seed 100,000 requests

The seeder only runs when `DOTNET_ENVIRONMENT=Development`:

```powershell
$env:DOTNET_ENVIRONMENT = "Development"
dotnet run --project src/RequestManagement.Seeder -- --count 100000
```

Without `--reset` the seeder requires a fully migrated, **empty** database. It never appends
to or overwrites existing data.

Target guards (recommended whenever more than one database or clone exists on the machine):

| Option | Effect |
|---|---|
| `--expect-server <s>` and `--expect-database <d>` (always together) | The seeder refuses to run unless the server and database in the connection string are exactly these (case-sensitive). The connection string must then come from the process environment; user-secrets are not used. |
| `--create-new` (needs both `--expect-*`) | Creates the database, applies the migrations and seeds it. Refuses if the database already exists; never drops anything. Mutually exclusive with `--reset`. |

```powershell
dotnet run --project src/RequestManagement.Seeder -- --count 100000 --expect-server "localhost,1433" --expect-database "RequestManagement"
```

### 6. Reset and regenerate (destructive, development only)

```powershell
$env:DOTNET_ENVIRONMENT = "Development"
dotnet run --project src/RequestManagement.Seeder -- --reset --count 100000
```

`--reset` drops the database named in the connection string, re-applies all migrations and
seeds again. It is refused unless `DOTNET_ENVIRONMENT=Development`, refused for system
databases (`master`, `model`, `msdb`, `tempdb`), and prints the target server and database
before it starts.

Other options: `--batch-size <n>` (default 10,000), `--seed <n>` (default 20261020), `--help`.

The seeder prints the row count, the distribution by status and priority, and a checksum.
The same `--count` and `--seed` always give the same rows, Ids and checksum.

### 7. Check the result directly in SQL Server

```powershell
docker exec request-management-sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<your password>" -C -d RequestManagement -Q "SELECT COUNT(*) AS Requests FROM dbo.Requests; SELECT MigrationId FROM dbo.__EFMigrationsHistory;"
```

## Run the API

From `backend`, with the connection string set as in [step 3](#3-configure-the-connection-string-never-committed)
(the API and the seeder share the same user-secrets entry; a `ConnectionStrings__RequestManagement`
environment variable also works):

```powershell
dotnet run --project src/RequestManagement.Api --launch-profile http
```

The API listens on <http://localhost:5080>. In Development it serves Swagger UI at
<http://localhost:5080/swagger> (OpenAPI document at `/openapi/v1.json`), which is the convenient
way to call the bulk endpoint, which has no screen in the UI.

Configuration (`appsettings.json`):

| Key | Default | Meaning |
|---|---|---|
| `SummaryCache:Enabled` | `true` | Caches the summary aggregation; `false` always recomputes it |
| `SummaryCache:ExpirationSeconds` | `60` | Absolute expiration of the cached summary (must be greater than 0) |

The summary cache is also invalidated after every committed status change (single or bulk).

`--launch-profile http` also opens your default browser (`launchBrowser: true`). To avoid that, run
with `--no-launch-profile` and set the two values the profile sets:
`$env:ASPNETCORE_ENVIRONMENT = "Development"; $env:ASPNETCORE_URLS = "http://localhost:5080"`.

## Run the UI

From `frontend` (the API must be running on port 5080):

```powershell
npm ci
npm start
```

Open <http://localhost:4200>. The dev server proxies `/api` to `http://localhost:5080`
(`frontend/proxy.conf.json`), so there is no CORS configuration. Search, filters, sorting and
paging are all done by the API; the search box is debounced and a newer query cancels the one
still in flight. The UI shows loading, empty and error states, the summary panel, status changes
(only the allowed next statuses are offered, and a 409 shows a message and reloads the row) and
the history of each request.

## API endpoints

| Method | Route | Success | Error codes |
|---|---|---|---|
| GET | `/api/requests` | 200 paged list | 400 |
| GET | `/api/requests/{id}` | 200 | 404 |
| GET | `/api/requests/summary` | 200 counts by status and priority, plus total (cached) | none |
| PATCH | `/api/requests/{id}/status` | 200 updated request with the new `rowVersion` | 400, 404, **409**, 422 |
| GET | `/api/requests/{id}/history` | 200 newest first | 404 |
| POST | `/api/requests/bulk-status` | 200 with one outcome per item | 400 |

Errors are `application/problem+json`; an unhandled error returns 500 without internals.
Enums travel as strings (`"InProgress"`).

**List query parameters.** `page` (>= 1, default 1), `pageSize` (1 to 100, default 20), `search`
(2 to 100 characters, case-insensitive contains on title or organization name), `status` and
`priority` (repeat the parameter for several values), `organizationName` (starts with),
`assignedTo` (exact), `createdFrom` (inclusive) and `createdTo` (exclusive, UTC), `sortBy`
(`createdAt` default, `updatedAt`, `priority`, `status`, `title`) and `sortDirection`
(`asc` or `desc`, default `desc`). All filters combine with AND; `Id` is the sort tie-breaker.

**Status update and concurrency.** Send the `rowVersion` from the last response. The update is
`UPDATE ... WHERE Id = @id AND RowVersion = @rv` in one transaction together with the history row.

```http
PATCH /api/requests/42/status
X-User-Name: dana
Content-Type: application/json

{ "status": "InProgress", "rowVersion": "AAAAAAAAB9E=" }
```

| Result | Meaning |
|---|---|
| 200 | Updated; `updatedAt` and `rowVersion` changed; a history row was added with `changedBy` from `X-User-Name` (default `anonymous`, at most 100 characters, not authenticated) |
| 400 | Malformed body, undefined status value, or header too long |
| 404 | No such request |
| 409 | Stale `rowVersion`; the body carries `currentStatus` and `currentRowVersion`, nothing is changed |
| 422 | Transition not allowed |

Allowed transitions (assumption A1): `New` to `InProgress` or `Waiting`; `InProgress` to `Waiting`
or `Completed`; `Waiting` to `InProgress` or `Completed`. `Completed` is final and setting the
same status again is rejected. The rules live only in `StatusTransitionPolicy`.

**Bulk update (Partial Success).** Up to 100 items, each with its own `rowVersion`. Every item is
applied independently with the same rules as the single update, in its own transaction, so one
stale item does not block the others. A valid call always returns 200 with one result per item,
in the order sent. The whole call is rejected with 400, and nothing is changed, when there are no
items, more than 100, duplicate ids, or a missing or malformed field.

```http
POST /api/requests/bulk-status
Content-Type: application/json

{ "status": "Waiting", "items": [ { "id": 1, "rowVersion": "AAAAAAAAB9E=" }, { "id": 999999999, "rowVersion": "AAAAAAAAB9E=" } ] }
```

```json
{
  "requested": 2, "succeeded": 1, "failed": 1,
  "results": [
    { "id": 1, "outcome": "Updated", "rowVersion": "<new version>", "error": null },
    { "id": 999999999, "outcome": "NotFound", "rowVersion": null, "error": "..." }
  ]
}
```

`outcome` is `Updated`, `NotFound`, `Conflict` (with the current `rowVersion` so the client can
retry) or `InvalidTransition`.

## Data model

**`Requests`**

| Column | Type | Constraint / note |
|---|---|---|
| `Id` | `int IDENTITY` | Clustered primary key |
| `Title` | `nvarchar(200)` | Required |
| `OrganizationName` | `nvarchar(200)` | Required |
| `Status` | `tinyint` | CHECK 1-4: New, InProgress, Waiting, Completed |
| `Priority` | `tinyint` | CHECK 1-3: Low, Medium, High (ordinal, so it sorts by importance) |
| `AssignedTo` | `nvarchar(100)` | Nullable: unassigned (assumption A3) |
| `CreatedAt`, `UpdatedAt` | `datetime2(3)` | UTC; CHECK `UpdatedAt >= CreatedAt` |
| `Version` | `rowversion` | Concurrency token, maintained by SQL Server |

**`RequestStatusHistory`**

| Column | Type | Constraint / note |
|---|---|---|
| `Id` | `bigint IDENTITY` | Primary key |
| `RequestId` | `int` | FK to `Requests.Id`, `ON DELETE NO ACTION` (audit rows are never cascaded away) |
| `PreviousStatus`, `NewStatus` | `tinyint` | CHECK 1-4 each; CHECK `PreviousStatus <> NewStatus` |
| `ChangedAt` | `datetime2(3)` | UTC |
| `ChangedBy` | `nvarchar(100)` | Required |

### Indexes and why

| Index | Migration | Query pattern it serves |
|---|---|---|
| `IX_RequestStatusHistory_RequestId_ChangedAt` (RequestId, ChangedAt DESC) | InitialCreate | History of one request, newest first; also the FK index |
| `IX_Requests_CreatedAt_Id` (CreatedAt DESC, Id DESC) | AddQueryIndexes | Default sort with the Id tie-breaker, date-range filter, deep pages |
| `IX_Requests_Status_CreatedAt` (Status, CreatedAt DESC) INCLUDE (Priority) | AddQueryIndexes | Status filter with the default sort; count by status |
| `IX_Requests_AssignedTo_Status_CreatedAt` (AssignedTo, Status, CreatedAt DESC) | AddQueryIndexes | A handler's queue (exact AssignedTo, optional status) |
| `IX_Requests_OrganizationName_CreatedAt` (OrganizationName, CreatedAt DESC) | AddQueryIndexes | Organization starts-with filter (`LIKE 'x%'` can seek) |
| `IX_Requests_Priority_Status` (Priority, Status) | AddQueryIndexes | Count by priority from a narrow index |

These are the plan's design (§4.3). One measurement per phase on the 100,000-row data set is in
[`docs/perf/PERFORMANCE.md`](docs/perf/PERFORMANCE.md): each index appears in at least one saved
execution plan after the indexes were restored, but no index was dropped and re-measured on its own, so no
index has been confirmed or removed on measured benefit alone. Contains-search on `Title` is not
index-backed by design (hypothesis H1; the report supports it).

## Seed data

- Deterministic: a fixed random seed and a fixed anchor date (2026-10-01 UTC), never the clock.
  Ids are written explicitly as 1..N (`SqlBulkCopy` with `KeepIdentity`).
- About 2,000 organizations (skewed: a few large, a long tail), 50 handlers (`handler-01`..`handler-50`),
  about 15% unassigned. Status: New 20%, InProgress 30%, Waiting 15%, Completed 35%.
  Priority: Low 40%, Medium 45%, High 15%. `CreatedAt` within the 24 months before the anchor.
- Seeded requests have no history rows (assumption A11).
- Bounded memory: rows are generated lazily and written in batches (default 10,000) through one
  reusable `DataTable`, so memory depends on the batch size, not on `--count`.
- One transaction: a failed or cancelled run leaves the database empty, not half-seeded.
- `SqlBulkCopy` runs with `CheckConstraints`, so CHECK constraints stay enforced and trusted.

## Tests

```powershell
cd backend
dotnet test tests/RequestManagement.UnitTests
dotnet test tests/RequestManagement.IntegrationTests

cd ../frontend
npm ci          # once
npm test -- --watch=false
npm run lint    # Angular lint (ESLint)
```

The integration tests start a SQL Server 2022 container with Testcontainers (Docker required).
Without Docker, point them at an existing SQL Server; they create and drop a uniquely named
`RequestManagement_Tests_<guid>` database:

```powershell
$env:TEST_SQL_CONNECTION = "Server=localhost\SQLEXPRESS;Integrated Security=True;TrustServerCertificate=True"
dotnet test tests/RequestManagement.IntegrationTests
```

## Design notes

### Database choice and how loading everything into memory is avoided

SQL Server 2022 with EF Core and a native `rowversion` column (decision D1): the database maintains
the concurrency token, so conflict detection is enforced server-side, and EF Core translates
filtering, sorting and paging to SQL. Every list request is one `WHERE ... ORDER BY ... OFFSET/FETCH`
query that projects straight into `RequestDto` (no entity is materialised or returned), plus a
`COUNT` query for `totalCount`; the summary is two `GROUP BY` queries. Nothing filters, sorts or
pages in application memory, and the Angular app never does either. The indexes and the query patterns
they serve are in [Indexes and why](#indexes-and-why).

**Measured once, with a limitation.** The 100,000-row measurement (query plans, logical reads, API
latency; plan T-501 to T-503) is in [`docs/perf/PERFORMANCE.md`](docs/perf/PERFORMANCE.md). In the
`after` phase only 3 of the 14 statements were marked plan-stable by the measurement script; the report
keeps that marking and does not claim that the improvements are caused by the indexes alone. This README
therefore quotes no performance numbers; read the report for them and for the caveats.

### Concurrency and bulk update

Single and bulk updates share one per-item routine (`RequestStatusService`). The client sends the
`rowVersion` it last saw; the status `UPDATE ... WHERE Id = @id AND RowVersion = @rv` and the history
`INSERT` commit in one transaction. Zero affected rows means someone else changed the request, and
the API returns 409 with the current status and version; nothing is overwritten. The UI shows the
message, locks the row until reloaded and does not retry on its own. The request/response examples
are in [API endpoints](#api-endpoints).

Bulk is **Partial Success** (decision D2): requests are independent, so one stale or missing item
should not force the user to redo 99 valid ones. Each item is applied in its own transaction and the
response lists `Updated`, `NotFound`, `Conflict` (with the current `rowVersion`) or `InvalidTransition`
per item, in the order sent. An invalid envelope (0 or more than 100 items, duplicate ids, missing
fields) is rejected with 400 and changes nothing.

### Cache and invalidation

Only the global summary (counts by status and priority, plus the total) is cached, in a singleton
`RequestSummaryCache` wrapping a lock and an in-memory entry (it does not use `IMemoryCache`; the plan,
D3 and §4.1, was corrected to say so). It is read by every user, aggregates all
rows, is small, and changes only on a status update, so the invalidation points are exact. Expiry is
`SummaryCache:ExpirationSeconds` (default 60). The status services call `Invalidate()` after every
committed single or bulk update. A generation counter stops a read that started before the commit from
storing its stale counts afterwards. `SummaryCache:Enabled=false` bypasses the cache.

With several server instances an in-memory cache is local to each, so the others would serve stale
counts until expiry. Described adjustment (not implemented): keep the entry in a shared cache such as
Redis through `IDistributedCache` and remove it on every update, or use `HybridCache` with Redis as the
second level and broadcast evictions; the short expiry remains the upper bound of staleness.

### Two technical decisions and their alternatives

1. **SQL Server with `rowversion`** (D1) instead of MongoDB with a hand-maintained version field, PostgreSQL
   with `xmin`, or Dapper with hand-written SQL. Chosen because the database itself enforces the version
   check and the plans are easy to inspect.
2. **Partial-Success bulk with one transaction per item** (D2) instead of All-or-Nothing. All-or-Nothing is
   simpler to explain but one conflict would fail the whole batch of up to 100; per-item transactions also
   keep lock time short. The cost is that the client must read the per-item results.

Other decisions and the assumptions about under-specified behaviour (allowed transitions, `ChangedBy`,
filter semantics, page-size limit) are listed in [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md) §3.

### Known limitations and possible improvements

- **Contains-search is not index-backed.** `search` is a case-insensitive *contains* on title or
  organization name, which cannot seek on a B-tree index; the measurement scans all 100,000 rows for its
  count query (hypothesis H1, see the performance report). Improvement: SQL Server full-text search, or
  keeping the 2-character minimum together with selective filters. Deep pages still scan and sort in the
  measurement; whether paging cost grows with the offset (H2) was not tested because only one offset was
  measured. Keyset pagination is the improvement.
- **`ChangedBy` is not authenticated.** It is whatever the client sends in `X-User-Name`; there is no
  authentication or authorisation (out of scope in the plan).
- **Shared `UserSecretsId`.** The Api and the Seeder share one user-secrets entry for all clones on the
  same Windows account (see [step 3](#3-configure-the-connection-string-never-committed)). Only the Seeder
  `--expect-*` guards and the environment variable protect against reaching the wrong database;
  `docs/perf/guard-perf-target.ps1` protects only the performance database. Not changed in code.
- **Fixed Docker settings.** `docker-compose.yml` fixes `container_name: request-management-sql`, and the
  README commands (step 7) use that name; a second instance needs an override file (see step 1).
- **Bulk request schema in OpenAPI.** The generated OpenAPI document and the Swagger example for
  `POST /api/requests/bulk-status` also list a `changes` array and a `rowVersionBytes` field per item, which
  are computed read-only properties of the DTO. The contract that works, and that the tests and the
  clean-clone check used, is `status` plus `items[] { id, rowVersion }`. Not fixed.
- **Narrow windows.** At about 800 px the requests table is wider than the viewport and the Update button
  is clipped; the UI was checked at 1400x900. "Clear filters" leaves the search box as it is.
- **Dev-tooling advisories.** `npm audit` reports 2 findings (undici through `@angular/build`), not addressed.

## AI usage

AI assistance (Claude Code, a Claude model) was used throughout this project, under the author's
direction and with the author approving the steps that touched the database or the repository:

| Area | AI-assisted | What was checked |
|---|---|---|
| Work plan (`docs/WORK_PLAN.md`) | Drafted and revised with AI; reviewed against the assignment PDF | Requirement catalogue and traceability cross-checked against the PDF; task statuses changed only with recorded evidence |
| Backend (Core, Infrastructure, Api, Seeder) | Written with AI | Unit tests (188) and integration tests against real SQL Server in Testcontainers (133), including the parallel-update test (IT-4) and error-shape tests; `dotnet format` and a 0-warnings build |
| Angular app | Written with AI | 62 Vitest tests, Angular lint (ESLint), `ng build`, and browser smoke checks S-1 to S-7 |
| Performance scripts (`docs/perf/`) | Written with AI | Offline self-tests passed on 2026-10-27: `test-perf-scripts.ps1` 572/572 and `test-guard.ps1` 18/18. They opened no database connection, so they show that the scripts' own logic and guards behave as designed, not that anything was measured. The scripts were then run live against the dedicated performance database (one run per phase, 2026-10-27); the first live run found a defect in the `sqlcmd` arguments that the offline tests could not see, which was fixed and covered by a new test. Results and their limitation: `docs/perf/PERFORMANCE.md`; notes: `docs/perf/DEVIATIONS.md` |
| Documentation (this README, verification log) | Written with AI | Commands compared with `launchSettings.json`, `proxy.conf.json`, `package.json`, the controllers and DTOs, and then followed in a clean clone |

**Code-quality review (T-603).** The AI-written code was read against nine checks (QC-1 to QC-9 in
`docs/WORK_PLAN.md`), all of which pass: `Core` has no EF or ASP.NET reference and only `requests-api.service.ts`
injects `HttpClient`; the single and bulk update share one routine and the list filters are written once;
controllers return only DTOs and ProblemDetails; no `.Result`, `.Wait()` or `async void`, and I/O calls
forward the `CancellationToken`; a 500 carries no stack trace; the three request types use one validation
mechanism; logs carry no bodies or connection strings; nothing from the plan's out-of-scope list was added.
What the review **changed**: Prettier formatting of 20 frontend files that did not satisfy the repository's
`.prettierrc`, four copies of the error-conversion expression replaced by one `toApiError`, and the missing
Angular linter (`angular-eslint` 21) added. The `IMemoryCache` mismatch between plan and code was found in the
review and then corrected in the plan (D3 and §4.1).

**Clean-clone verification (T-604).** Every run step and smoke check passed in a fresh clone against a
separate temporary SQL Server instance; the deviations from the README and the findings are in
[`docs/verification-log.md`](docs/verification-log.md).

**The author's part.** The author describes their part as reviewing the AI's work. The repository records
these decisions of the author: approving each step that touched the database or the repository (the
performance database steps, the temporary SQL Server instance of the T-604 clean-clone check); approving the
two extra performance scenarios B1e and B1f ([`docs/perf/DEVIATIONS.md`](docs/perf/DEVIATIONS.md), deviation
E); and deciding not to clear the plan cache or repeat the `after` measurement, which is why 11 of its 14
statements stay `PLAN_UNSTABLE` ([`docs/perf/PERFORMANCE.md`](docs/perf/PERFORMANCE.md), section 7). The repository
does not show whether the author wrote or edited anything by hand, and this README makes no claim about it.

## Dependencies and why

Backend (versions are centralised in `backend/Directory.Packages.props`):

| Package | Why |
|---|---|
| `Microsoft.EntityFrameworkCore.SqlServer` 10.0.13 | Data access; its SQL Server client is also used for `SqlBulkCopy` in the seeder |
| `Microsoft.EntityFrameworkCore.Design` 10.0.13 | `dotnet ef` migrations |
| `Microsoft.AspNetCore.OpenApi` 10.0.0, `Swashbuckle.AspNetCore.SwaggerUI` 10.0.0 | OpenAPI document and Swagger UI (Development only) so reviewers can call every endpoint, including bulk |
| `Microsoft.Extensions.Configuration.UserSecrets` / `.EnvironmentVariables` 10.0.0 | Seeder connection string outside the repository |
| `Microsoft.OpenApi` 2.7.5, `System.Security.Cryptography.Pkcs` 9.0.21 | Version pins for transitive packages with published security advisories |
| `xunit` 2.9.3, `xunit.runner.visualstudio`, `Microsoft.NET.Test.Sdk` | Test framework; plain xUnit asserts, no assertion library |
| `Testcontainers.MsSql` 4.16.0 | Real SQL Server for the integration tests (`rowversion` and `LIKE` need the real engine) |
| `Microsoft.AspNetCore.Mvc.Testing` 10.0.0 | Hosts the API in-process for integration tests |

Frontend (`frontend/package.json`): Angular 21 with Angular Material and CDK (table, paginator, dialog,
snackbar), RxJS (debounce and request cancellation), Vitest and jsdom (the Angular 21 default test runner),
Prettier (formatting), ESLint with `angular-eslint` and `typescript-eslint` (the Angular lint of QC-2, `npm run lint`).
