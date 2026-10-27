-- T-501 captured SQL: the command text and parameters EF Core really builds
-- scenario: B1f
-- operation: GET /api/requests, organization starts-with
-- request: organizationName=Aurora&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20
-- captured from commit: 9db54a1; backend/src: identical to HEAD 9db54a1 (git status of backend/src is clean; only backend/tests changed)
-- tool: PerfSqlCaptureTests runs the real RequestQueryService; an EF interceptor records each command and no database is contacted
-- statements, in execution order: count, data
-- Commands with parameters are written as the EXEC sp_executesql call SqlClient sends: declared types come from the SqlParameter objects EF built
-- (a string with no explicit size is declared nvarchar(4000), or nvarchar(max) above 4,000 characters, as SqlClient does).
-- Line breaks inside the command text are normalised to LF.

-- part: count
EXEC sp_executesql N'SELECT COUNT(*)
FROM [Requests] AS [r]
WHERE [r].[OrganizationName] LIKE @prefix ESCAPE N''\''', N'@prefix nvarchar(200)', @prefix = N'Aurora%';
GO

-- part: data
EXEC sp_executesql N'SELECT [r].[Id], [r].[Title], [r].[OrganizationName], [r].[Status], [r].[Priority], [r].[AssignedTo], [r].[CreatedAt], [r].[UpdatedAt], [r].[Version]
FROM [Requests] AS [r]
WHERE [r].[OrganizationName] LIKE @prefix ESCAPE N''\''
ORDER BY [r].[CreatedAt] DESC, [r].[Id] DESC
OFFSET @p ROWS FETCH NEXT @p3 ROWS ONLY', N'@prefix nvarchar(200), @p int, @p3 int', @prefix = N'Aurora%', @p = 0, @p3 = 20;
GO
