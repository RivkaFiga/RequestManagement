# Clean-clone verification log (T-604)

**Status: all run steps and smoke checks S-1 to S-7 passed in the clean clone, with documented deviations. T-604 is still In Progress, not Done** (see "Follow-up after the run" and "Why T-604 is not marked Done").

## Setup

- Date: 2026-10-27. Windows 11, .NET SDK 10.0.402, Node v22.22.0, npm 11.8.0, Docker Server 29.6.1.
- Commit verified: `9db54a1a44e49f13260e342900818a578c0d993b` (`add T-606`), branch `feature/request-summary`. The working copy was clean when the clone was made, so the clone equals the working copy.
- Clone: `git clone --no-hardlinks <working copy> C:\rmc-t604\repo` (an ASCII path without spaces, as the README advises). Clone `git status --short` is empty at the end (`.env`, `bin`, `obj`, `node_modules`, `dist` are git-ignored).
- Two earlier clone attempts were discarded without running anything: one under the session scratchpad failed at checkout (`Filename too long`), one under `%TEMP%` resolved to a non-ASCII path with a space.
- No `TEST_SQL_CONNECTION` or `ConnectionStrings__*` variable was set at the start of the session.

## Part 1: build and tests (before the database part)

| # | Directory | Command | Result |
|---|---|---|---|
| 1 | `backend` | `dotnet tool restore` | exit 0, `dotnet-ef 10.0.0` |
| 2 | `backend` | `dotnet build` | exit 0, 0 warnings, 0 errors |
| 3 | `backend` | `dotnet format RequestManagement.sln --verify-no-changes --no-restore` | exit 0 |
| 4 | `backend` | `dotnet test tests/RequestManagement.UnitTests --no-build` | 188 passed, 0 failed |
| 5 | `backend` | `dotnet test tests/RequestManagement.IntegrationTests --no-build` | 133 passed, 0 failed (Testcontainers, own throw-away container, image already local) |
| 6 | `frontend` | `npm ci` | exit 0, 592 packages; `npm audit`: 2 vulnerabilities (1 moderate, 1 high), already noted under T-603 |
| 7 | `frontend` | `npm test -- --watch=false` | 7 files, 62 tests passed |
| 8 | `frontend` | `npm run lint` | "All files pass linting." |
| 9 | `frontend` | `npx ng build` | exit 0 |

## Part 2: isolated database, seed, API, UI

### Isolation design (approved by the user: alternative B)

A **separate, temporary SQL Server instance** so that the existing server cannot be touched by construction:

| Item | Existing (not touched) | T-604 instance |
|---|---|---|
| Container | `request-management-sql` | `rm-t604-sql` |
| Port | 1433 | 14331 |
| Compose project / volume | `requestmanagement` / `requestmanagement_sqlserver-data` | `rmc-t604` / `rmc-t604_sqlserver-data` |
| Database | `RequestManagement` and three others | `RequestManagement_T604` only |
| SQL Server host id | `1f31db4a5017` | `ff84e92bba63` |

- `C:\rmc-t604\repo\.env` (clone only, matched by `.gitignore:15`, not listed by `git status`) holds a freshly generated random sa password and `MSSQL_PORT=14331`. The password was never printed or written to Git. The user-secrets store (which has an entry pointing at `localhost,1433` / `RequestManagement`, shared through the same `UserSecretsId`) was not read for its password and not changed; every command used the `ConnectionStrings__RequestManagement` environment variable of its own process, which takes precedence.
- `C:\rmc-t604\docker-compose.t604.yml` (outside the repository) only sets `container_name: rm-t604-sql`.
- Before each database-changing command a guard checked that the connection string names exactly `localhost,14331` and `RequestManagement_T604` (it stops otherwise). `dotnet ef dbcontext info` printed `Database name: RequestManagement_T604`, `Data source: localhost,14331` before the migration. The Seeder was run with `--expect-server` / `--expect-database`, which make it refuse any other target and refuse to use user-secrets.
- Baseline of the existing server taken before (read-only `SELECT`s): databases and sizes, `COUNT(*)`, `CHECKSUM_AGG`, `MAX(UpdatedAt)` of `RequestManagement.dbo.Requests` (100,000 rows, checksum -1953119262), history rows (0) and the migration list.

### Commands and results

| # | Command (in the clone) | Result |
|---|---|---|
| 10 | `docker compose -p rmc-t604 -f docker-compose.yml -f ..\docker-compose.t604.yml config --quiet` | exit 0; resolved: `rm-t604-sql`, `14331->1433`, volume `rmc-t604_sqlserver-data` |
| 11 | `docker compose -p rmc-t604 -f docker-compose.yml -f ..\docker-compose.t604.yml up -d` | network, volume and container created, healthy after about 20 s; only the four system databases inside |
| 12 | `dotnet ef database update --project src/RequestManagement.Infrastructure --startup-project src/RequestManagement.Infrastructure` (connection string from the environment) | exit 0; applied `20261020183000_InitialCreate` and `20261020183100_AddQueryIndexes`; `RequestManagement_T604` created, 0 requests |
| 13 | `dotnet run --project src/RequestManagement.Seeder -- --count 100000 --expect-server "localhost,14331" --expect-database "RequestManagement_T604"` with `DOTNET_ENVIRONMENT=Development` | exit 0; 100,000 rows in 4.2 s; New=19,831, InProgress=29,844, Waiting=14,982, Completed=35,343; Low=40,005, Medium=45,166, High=14,829; checksum **-1953119262**, the same as the existing `RequestManagement` database |
| 14 | `dotnet run --project src/RequestManagement.Api --no-launch-profile` with `ASPNETCORE_ENVIRONMENT=Development`, `ASPNETCORE_URLS=http://localhost:5080` and the connection string in the environment | `GET /api/requests/summary` returned 200 with total 100,000 and the seeded distribution; the only established SQL connection of the host was to port 14331 |
| 15 | `npm start` in `frontend` | `http://localhost:4200` returned 200 |

`--reset`, `--create-new`, BACKUP/RESTORE and any other destructive action were not used.

### Smoke checks (built-in browser pane, UI on :4200, Swagger UI on :5080)

| Check | Result | Evidence |
|---|---|---|
| S-1 | **Pass** | List loads with "100000 Total". Next, Last (`1 – 20` to `99981 – 100000 of 100000`, `page=5000`), Previous (`99961 – 99980`, `page=4999`), First, Next (`21 – 40`) each sent `GET /api/requests?page=N&pageSize=20` and returned 200. A click on Last right after Next cancelled the page-2 request (`ERR_ABORTED`), as designed. |
| S-2 | **Pass** | Network tab, one request per action: `search=archive` (7 typed characters, one request, 5,819 matches); `sortBy=status&sortDirection=asc`; `status=InProgress&status=Waiting` (2,607); `priority=High&organizationName=Aurora` added (61 rows; every row checked: organization starts with Aurora, High, In progress or Waiting, matches "archive"). |
| S-3 | **Pass** | Loading: a `mat-progress-bar` was observed (DOM observer) while paging. Empty: a search with no matches shows "No requests match the current filters." Error: after stopping the API, paging showed "Request failed (500)." (from the dev proxy) with a Retry button; after restarting the API, Retry loaded the page. |
| S-4 | **Pass** | Request 13375 (New): the select offered only In progress and Waiting; PATCH `/api/requests/13375/status` returned 200 and the row showed In progress. In a second tab holding the stale row, PATCH to Waiting returned **409 Conflict**; the message said the request "was changed by someone else, so your change was not saved. It is now In progress", the row was locked ("Reload the data to change this request"), exactly one PATCH was sent (no retry); "Reload data" refreshed the row to In progress. History row: New to In progress, `anonymous`. |
| S-5 | **Pass** | Summary before the change: New 19,831, In progress 29,844. After the 200: New 19,830, In progress 29,845, list and summary reloaded. The 409 in the other tab changed nothing. |
| S-6 | **Pass** | History dialog for #13375 (`GET /api/requests/13375/history`, 200): one entry, "New → In progress", changed by `anonymous`. |
| S-7 | **Pass** | Swagger UI, `POST /api/requests/bulk-status`, status InProgress, 5 items: 200, `requested 5, succeeded 2, failed 3`; 43687 `Updated`, 999999999 `NotFound`, 93838 `Conflict` (stale rowVersion, current rowVersion returned), 62035 `InvalidTransition` ("Completed is final"), 51545 `Updated`, in the order sent. A first attempt returned 400 because the browser tool had turned the body into `[object Object]`; it changed nothing, and the body was then typed in. |

Log sample (R10.8, from the API console): `Request 13375 changed from New to InProgress by anonymous.`, `Status update of request 13375 rejected: stale row version.`, `Request 43687 changed from New to InProgress by anonymous.`, `Status update of request 93838 rejected: stale row version.` No connection string or password appears.

### Isolation re-check after the run

- Existing server, same baseline query: **identical** (all four `RequestManagement*` databases and sizes; `RequestManagement` still 100,000 rows, checksum -1953119262, max `UpdatedAt` 2026-09-30 23:57:16.243, 0 history rows, both migrations). `request-management-sql` still `Up 3 hours (healthy)`; volume `requestmanagement_sqlserver-data` present.
- T-604 instance: database `RequestManagement_T604` only (plus system databases); 100,000 requests, 3 history rows (13375, 43687, 51545, each New to In progress, `anonymous`), so its checksum is now -1022857429 as expected after the changes.
- The API and Angular processes started for this check were stopped by process id (5080 and 4200 no longer listen). `rm-t604-sql`, `rmc-t604_sqlserver-data`, `C:\rmc-t604\repo`, `C:\rmc-t604\docker-compose.t604.yml` and the clone `.env` were left in place for the user to decide on cleanup.

## Deviations from the README (all documented)

1. **Step 1 (compose):** the README starts one SQL Server from `.env` with port 1433. Here a second instance with its own name, port and volume was started, with a compose override file and `MSSQL_PORT=14331`, because 1433 and the container name were already used by the development container.
2. **Step 3 (user-secrets):** not used; the connection string was passed through the process environment (the README says this also works). Database name `RequestManagement_T604` instead of `RequestManagement`.
3. **Step 5 (Seeder):** run with `--expect-server` and `--expect-database` (not in the README).
4. **API start:** `--no-launch-profile` with `ASPNETCORE_ENVIRONMENT` and `ASPNETCORE_URLS` set, instead of `--launch-profile http`, so that the profile's `launchBrowser: true` did not open the user's default browser. The profile otherwise only sets the same two values. The restart after the S-3 error test also used `--no-build`.
5. **UI:** `npm start`, then checked in the built-in browser pane (not a separate Chrome).

## Findings

1. The README does not mention `--create-new`, `--expect-server` and `--expect-database` of the Seeder, nor that the user-secrets entry is shared by the clone and the original through the same `UserSecretsId` (a clone run without the environment variable would reach the original database). `docs/perf/guard-perf-target.ps1` protects only the performance database.
2. A reviewer on the same machine as another SQL container hits the fixed `container_name` and port 1433 in `docker-compose.yml`; the README gives no way to change the container name.
3. The OpenAPI document and the Swagger example body for `POST /api/requests/bulk-status` list a `changes` array (`BulkStatusChange`) and, in the item, `rowVersionBytes`, besides `items` / `rowVersion` that the README documents and that worked. Not investigated further; the README contract (`items`) was used and passed.
4. "Clear filters" resets the filter fields but leaves the search box as it is (a search for no matches was therefore typed after "archive"); recorded as an observation, not as a defect.
5. In the narrow default browser pane (about 800 px) the requests table is wider than the viewport and the Update button is clipped; the S-4 to S-6 checks used an emulated 1400x900 viewport (reset afterwards). Observation only.

## Follow-up after the run (2026-10-27, documentation only; nothing below was re-run)

| Finding / deviation | Handled in | State |
|---|---|---|
| Finding 1 (Seeder `--create-new` / `--expect-*` undocumented; shared `UserSecretsId`) | README step 3 (warning box) and step 5 (guard table); "Known limitations" | Documented. Code unchanged: both projects still use `request-management-dev`. |
| Finding 2 (fixed `container_name`, port) | README step 1 (second-instance recipe), step 7 note; "Known limitations" | Documented. `docker-compose.yml` unchanged: `container_name` is still fixed. |
| Finding 3 (OpenAPI lists `changes` / `rowVersionBytes` for bulk) | README "Known limitations" | Documented, not investigated further, not fixed. |
| Findings 4 and 5 (Clear filters keeps the search box; table clipped at about 800 px) | README "Known limitations" | Documented as observations. |
| Deviation 4 (`--no-launch-profile`) | README "Run the API" | Documented. |
| `npm audit` (2 findings) | README "Known limitations" | Documented, not addressed. |

The added README paragraphs describe behaviour that this run already exercised; no command was executed to confirm the new text itself.

## Why T-604 is not marked Done

- The criterion is that "every step and smoke check passes with no undocumented action". Every step and S-1 to S-7 passed, and every deviation and finding is now documented (the README now covers deviations 1 to 4), but the README text added afterwards was not re-followed.
- T-604 depends on T-601 to T-603: T-601 is Done; T-602 and T-603 were In Progress when the run was made. Later on 2026-10-27, T-602 was marked Done (the README "AI usage" section now has "The author's part", limited to what the author confirmed and the repository records); T-603 still waits for the commit.
- The verification is "the committed log"; nothing was committed (no commit was requested).
- The instance `rm-t604-sql`, its volume `rmc-t604_sqlserver-data` and the clone `C:\rmc-t604` are still in place; cleanup was not requested.
