-- T-501 captured SQL: the command text and parameters EF Core really builds
-- scenario: B1a
-- operation: GET /api/requests, filtered
-- request: status=InProgress&priority=High&createdFrom=2026-07-03T00:00:00Z&createdTo=2026-10-01T00:00:00Z&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20
-- captured from commit: bfc3a18; backend/src: query-shaping sources (Core, Infrastructure/Requests, Infrastructure/Persistence) identical to HEAD; HEAD backend/src tree df8d2e0daa25ed1489c6025dc974535680cb77b7; uncommitted Seeder guard patch in Seeder and DatabaseSeeder only
-- tool: PerfSqlCaptureTests runs the real RequestQueryService; an EF interceptor records each command and no database is contacted
-- statements, in execution order: count, data
-- Commands with parameters are written as the EXEC sp_executesql call SqlClient sends: declared types come from the SqlParameter objects EF built
-- (a string with no explicit size is declared nvarchar(4000), or nvarchar(max) above 4,000 characters, as SqlClient does).
-- Line breaks inside the command text are normalised to LF.

-- part: count
EXEC sp_executesql N'SELECT COUNT(*)
FROM [Requests] AS [r]
WHERE [r].[Status] = @statuses1 AND [r].[Priority] = @priorities1 AND [r].[CreatedAt] >= @fromUtc AND [r].[CreatedAt] < @toUtc', N'@statuses1 tinyint, @priorities1 tinyint, @fromUtc datetime2(3), @toUtc datetime2(3)', @statuses1 = 2, @priorities1 = 3, @fromUtc = '2026-07-03T00:00:00.0000000', @toUtc = '2026-10-01T00:00:00.0000000';
GO

-- part: data
EXEC sp_executesql N'SELECT [r].[Id], [r].[Title], [r].[OrganizationName], [r].[Status], [r].[Priority], [r].[AssignedTo], [r].[CreatedAt], [r].[UpdatedAt], [r].[Version]
FROM [Requests] AS [r]
WHERE [r].[Status] = @statuses1 AND [r].[Priority] = @priorities1 AND [r].[CreatedAt] >= @fromUtc AND [r].[CreatedAt] < @toUtc
ORDER BY [r].[CreatedAt] DESC, [r].[Id] DESC
OFFSET @p ROWS FETCH NEXT @p5 ROWS ONLY', N'@statuses1 tinyint, @priorities1 tinyint, @fromUtc datetime2(3), @toUtc datetime2(3), @p int, @p5 int', @statuses1 = 2, @priorities1 = 3, @fromUtc = '2026-07-03T00:00:00.0000000', @toUtc = '2026-10-01T00:00:00.0000000', @p = 0, @p5 = 20;
GO
