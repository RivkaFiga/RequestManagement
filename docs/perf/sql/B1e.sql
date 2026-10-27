-- T-501 captured SQL: the command text and parameters EF Core really builds
-- scenario: B1e
-- operation: GET /api/requests, a handler's queue
-- request: assignedTo=handler-07&status=InProgress&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20
-- captured from commit: 9db54a1; backend/src: identical to HEAD 9db54a1 (git status of backend/src is clean; only backend/tests changed)
-- tool: PerfSqlCaptureTests runs the real RequestQueryService; an EF interceptor records each command and no database is contacted
-- statements, in execution order: count, data
-- Commands with parameters are written as the EXEC sp_executesql call SqlClient sends: declared types come from the SqlParameter objects EF built
-- (a string with no explicit size is declared nvarchar(4000), or nvarchar(max) above 4,000 characters, as SqlClient does).
-- Line breaks inside the command text are normalised to LF.

-- part: count
EXEC sp_executesql N'SELECT COUNT(*)
FROM [Requests] AS [r]
WHERE [r].[Status] = @statuses1 AND [r].[AssignedTo] = @assignedTo', N'@statuses1 tinyint, @assignedTo nvarchar(100)', @statuses1 = 2, @assignedTo = N'handler-07';
GO

-- part: data
EXEC sp_executesql N'SELECT [r].[Id], [r].[Title], [r].[OrganizationName], [r].[Status], [r].[Priority], [r].[AssignedTo], [r].[CreatedAt], [r].[UpdatedAt], [r].[Version]
FROM [Requests] AS [r]
WHERE [r].[Status] = @statuses1 AND [r].[AssignedTo] = @assignedTo
ORDER BY [r].[CreatedAt] DESC, [r].[Id] DESC
OFFSET @p ROWS FETCH NEXT @p3 ROWS ONLY', N'@statuses1 tinyint, @assignedTo nvarchar(100), @p int, @p3 int', @statuses1 = 2, @assignedTo = N'handler-07', @p = 0, @p3 = 20;
GO
