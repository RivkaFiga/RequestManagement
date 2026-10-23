-- T-501 captured SQL: the command text and parameters EF Core really builds
-- scenario: B1c
-- operation: GET /api/requests, text search
-- request: search=payroll&status=New&page=1&pageSize=20
-- captured from commit: bfc3a18; backend/src: query-shaping sources (Core, Infrastructure/Requests, Infrastructure/Persistence) identical to HEAD; HEAD backend/src tree df8d2e0daa25ed1489c6025dc974535680cb77b7; uncommitted Seeder guard patch in Seeder and DatabaseSeeder only
-- tool: PerfSqlCaptureTests runs the real RequestQueryService; an EF interceptor records each command and no database is contacted
-- statements, in execution order: count, data
-- Commands with parameters are written as the EXEC sp_executesql call SqlClient sends: declared types come from the SqlParameter objects EF built
-- (a string with no explicit size is declared nvarchar(4000), or nvarchar(max) above 4,000 characters, as SqlClient does).
-- Line breaks inside the command text are normalised to LF.

-- part: count
EXEC sp_executesql N'SELECT COUNT(*)
FROM [Requests] AS [r]
WHERE ([r].[Title] LIKE @pattern ESCAPE N''\'' OR [r].[OrganizationName] LIKE @pattern ESCAPE N''\'') AND [r].[Status] = @statuses1', N'@pattern nvarchar(200), @statuses1 tinyint', @pattern = N'%payroll%', @statuses1 = 1;
GO

-- part: data
EXEC sp_executesql N'SELECT [r].[Id], [r].[Title], [r].[OrganizationName], [r].[Status], [r].[Priority], [r].[AssignedTo], [r].[CreatedAt], [r].[UpdatedAt], [r].[Version]
FROM [Requests] AS [r]
WHERE ([r].[Title] LIKE @pattern ESCAPE N''\'' OR [r].[OrganizationName] LIKE @pattern ESCAPE N''\'') AND [r].[Status] = @statuses1
ORDER BY [r].[CreatedAt] DESC, [r].[Id] DESC
OFFSET @p ROWS FETCH NEXT @p6 ROWS ONLY', N'@pattern nvarchar(200), @statuses1 tinyint, @p int, @p6 int', @pattern = N'%payroll%', @statuses1 = 1, @p = 0, @p6 = 20;
GO
