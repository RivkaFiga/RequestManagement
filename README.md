# Request Management System

Full-stack take-home: .NET backend, SQL Server, Angular frontend.
The work plan is in [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md).

> **Status:** the backend (search, summary, status update with optimistic concurrency, history,
> bulk update, summary cache), the Angular app and their automated tests are implemented.
> The performance measurement ([`docs/perf/`](docs/perf)) and the design write-up
> (decisions, limitations, AI usage; plan T-501 to T-503 and T-602) are **not finished yet**, so
> this README has no performance numbers. Task status and evidence: [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md).

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| .NET SDK | 10.0.1xx or later feature band (`backend/global.json`; developed with 10.0.402) | Build, tests, EF Core tools |
| Node.js + npm | Node 22 LTS, npm 10 or later (developed with Node 22.22.0, npm 11.8.0; `frontend/package.json` pins `npm@10.9.4`) | Angular app and its tests |
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
docs/                                  WORK_PLAN.md, perf/ (measurement scripts and assets)
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

These are the plan's hypotheses (§4.3). Phase 5 measures them on the 100,000-row data set
and drops any index that shows no benefit; contains-search on `Title` is not index-backed
by design (hypothesis H1).

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
