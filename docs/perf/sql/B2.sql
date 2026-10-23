-- T-501 captured SQL: the command text and parameters EF Core really builds
-- scenario: B2
-- operation: GET /api/requests/summary
-- request: (no parameters; cache miss, so both GROUP BY queries run)
-- captured from commit: bfc3a18; backend/src: query-shaping sources (Core, Infrastructure/Requests, Infrastructure/Persistence) identical to HEAD; HEAD backend/src tree df8d2e0daa25ed1489c6025dc974535680cb77b7; uncommitted Seeder guard patch in Seeder and DatabaseSeeder only
-- tool: PerfSqlCaptureTests runs the real RequestQueryService; an EF interceptor records each command and no database is contacted
-- statements, in execution order: status, priority
-- Commands with parameters are written as the EXEC sp_executesql call SqlClient sends: declared types come from the SqlParameter objects EF built
-- (a string with no explicit size is declared nvarchar(4000), or nvarchar(max) above 4,000 characters, as SqlClient does).
-- Line breaks inside the command text are normalised to LF.

-- part: status
SELECT [r].[Status], COUNT(*)
FROM [Requests] AS [r]
GROUP BY [r].[Status];
GO

-- part: priority
SELECT [r].[Priority], COUNT(*)
FROM [Requests] AS [r]
GROUP BY [r].[Priority];
GO
