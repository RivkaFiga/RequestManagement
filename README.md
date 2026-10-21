# Request Management System

Full-stack take-home: .NET backend, SQL Server, Angular frontend.
The work plan is in [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md).

> **Status: Phase 1 (foundation and data layer) only.** The API (Phase 2) and the Angular
> app (Phase 3) do not exist yet. The rest of this README is completed in Phase 6 (T-601/T-602).

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| .NET SDK | 10.0.1xx or later feature band (`backend/global.json`) | Build, tests, EF Core tools |
| Docker Desktop (Linux containers) | any current | Development SQL Server and the integration tests |

Without Docker: use SQL Server Express or LocalDB and put its connection string in the
steps below; for the integration tests set `TEST_SQL_CONNECTION` (see [Tests](#tests)).

Tip: keep the repository in an ASCII path without spaces (for example `C:\dev\request-management`);
the Angular tooling in later phases is sensitive to such paths (plan F3/R-07).

## Solution structure (Phase 1)

```
backend/
  RequestManagement.sln, global.json, Directory.Build.props, Directory.Packages.props
  .config/dotnet-tools.json            dotnet-ef (local tool)
  src/RequestManagement.Core           Domain: Request, RequestStatusHistoryEntry, enums, StatusTransitionPolicy
  src/RequestManagement.Infrastructure EF Core DbContext, mappings, migrations, seeding logic
  src/RequestManagement.Seeder         Console app: seed / reset the development database
  tests/RequestManagement.UnitTests    Model mapping, generator, seeder arguments, transition rules
  tests/RequestManagement.IntegrationTests  Seeding, reset and constraints against real SQL Server
docker-compose.yml                     Development SQL Server 2022
```

`Core` references neither EF Core nor ASP.NET Core.

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
```

The integration tests start a SQL Server 2022 container with Testcontainers (Docker required).
Without Docker, point them at an existing SQL Server; they create and drop a uniquely named
`RequestManagement_Tests_<guid>` database:

```powershell
$env:TEST_SQL_CONNECTION = "Server=localhost\SQLEXPRESS;Integrated Security=True;TrustServerCertificate=True"
dotnet test tests/RequestManagement.IntegrationTests
```
