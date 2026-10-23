using System.Data;
using System.Data.Common;
using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Options;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;
using RequestManagement.Infrastructure.Seeding;

namespace RequestManagement.UnitTests;

/// <summary>
/// T-501: captures the SQL that EF Core really sends for the measured scenarios B1a to B1d and B2 (work plan §5.1).
/// The real <see cref="RequestQueryService"/> runs; an interceptor records every command (text and parameters) and answers it
/// with a canned empty result, so no database is contacted. The tests always run and check the shape of the captured SQL
/// (R6.5). When <c>T501_SQL_OUT</c> names a directory they also write one <c>.sql</c> file per scenario there;
/// <c>T501_COMMIT</c> and <c>T501_SRC_STATE</c> (set by the caller) are recorded in the file headers.
/// </summary>
public class PerfSqlCaptureTests
{
    private static readonly DateTimeOffset Anchor = new(SeedOptions.DefaultAnchorUtc);

    private static readonly Scenario[] Scenarios =
    [
        new(
            "B1a",
            "GET /api/requests, filtered",
            $"status=InProgress&priority=High&createdFrom={Iso(Anchor.AddDays(-90))}&createdTo={Iso(Anchor)}&sortBy=createdAt&sortDirection=desc&page=1&pageSize=20",
            (service, ct) => service.SearchAsync(new RequestSearchQuery
            {
                Status = [RequestStatus.InProgress],
                Priority = [RequestPriority.High],
                CreatedFrom = Anchor.AddDays(-90),
                CreatedTo = Anchor,
                SortBy = "createdAt",
                SortDirection = "desc",
                Page = 1,
                PageSize = 20,
            }, ct),
            ["count", "data"]),
        new(
            "B1b",
            "GET /api/requests, deep page",
            "sortBy=createdAt&sortDirection=desc&page=2500&pageSize=20",
            (service, ct) => service.SearchAsync(new RequestSearchQuery
            {
                SortBy = "createdAt",
                SortDirection = "desc",
                Page = 2500,
                PageSize = 20,
            }, ct),
            ["count", "data"]),
        new(
            "B1c",
            "GET /api/requests, text search",
            "search=payroll&status=New&page=1&pageSize=20",
            (service, ct) => service.SearchAsync(new RequestSearchQuery
            {
                Search = "payroll",
                Status = [RequestStatus.New],
                Page = 1,
                PageSize = 20,
            }, ct),
            ["count", "data"]),
        new(
            "B1d",
            "GET /api/requests, alternate sort",
            "sortBy=title&sortDirection=asc&page=1&pageSize=20",
            (service, ct) => service.SearchAsync(new RequestSearchQuery
            {
                SortBy = "title",
                SortDirection = "asc",
                Page = 1,
                PageSize = 20,
            }, ct),
            ["count", "data"]),
        new(
            "B2",
            "GET /api/requests/summary",
            "(no parameters; cache miss, so both GROUP BY queries run)",
            (service, ct) => service.GetSummaryAsync(ct),
            ["status", "priority"]),
    ];

    [Fact]
    public async Task CapturedSql_HasTheExpectedShape_ForEveryScenario()
    {
        var captured = await CaptureAllAsync();

        foreach (var scenario in Scenarios)
        {
            Assert.Equal(scenario.Parts.Length, captured[scenario.Id].Count);
        }

        // B1a: every filter, the default sort with the Id tie-breaker, OFFSET/FETCH; the count has the same WHERE and no sort or paging.
        var b1a = captured["B1a"];
        Assert.StartsWith("SELECT COUNT(*)", b1a[0].Text);
        Assert.DoesNotContain("ORDER BY", b1a[0].Text);
        Assert.DoesNotContain("OFFSET", b1a[0].Text);
        Assert.Equal(WhereClause(b1a[1].Text), WhereClause(b1a[0].Text));
        foreach (var column in new[] { "[Status]", "[Priority]", "[CreatedAt]" })
        {
            Assert.Contains(column, WhereClause(b1a[0].Text));
        }

        Assert.Contains("[CreatedAt] DESC, [r].[Id] DESC", b1a[1].Text);
        Assert.Contains("OFFSET", b1a[1].Text);
        Assert.Contains("FETCH NEXT", b1a[1].Text);

        // The page query selects the 9 columns of the projection (R1.9: no entity, no tracking).
        foreach (var column in new[] { "Id", "Title", "OrganizationName", "Status", "Priority", "AssignedTo", "CreatedAt", "UpdatedAt", "Version" })
        {
            Assert.Contains($"[r].[{column}]", b1a[1].Text);
        }

        // B1b: no filter at all, and the offset is the one the scenario fixes (49,980 = (2,500 - 1) * 20).
        var b1b = captured["B1b"];
        Assert.DoesNotContain("WHERE", b1b[0].Text);
        Assert.DoesNotContain("WHERE", b1b[1].Text);
        Assert.Contains(b1b[1].Parameters, p => Convert.ToInt64(p.Value, CultureInfo.InvariantCulture) == 49_980);
        Assert.Contains(b1b[1].Parameters, p => Convert.ToInt64(p.Value, CultureInfo.InvariantCulture) == 20);

        // B1c: escaped LIKE over Title and OrganizationName, plus the Status filter.
        var b1c = captured["B1c"];
        Assert.Contains("LIKE", b1c[0].Text);
        Assert.Contains("ESCAPE", b1c[0].Text);
        Assert.Contains("[Title]", WhereClause(b1c[0].Text));
        Assert.Contains("[OrganizationName]", WhereClause(b1c[0].Text));
        Assert.Contains("[Status]", WhereClause(b1c[0].Text));
        Assert.Contains(b1c[0].Parameters, p => Equals(p.Value, "%payroll%"));
        Assert.Equal(WhereClause(b1c[1].Text), WhereClause(b1c[0].Text));

        // B1d: sort by Title ascending, tie-broken by Id ascending.
        var b1d = captured["B1d"];
        Assert.Contains("ORDER BY [r].[Title], [r].[Id]", b1d[1].Text);
        Assert.DoesNotContain("DESC", b1d[1].Text);

        // B2: the two server-side GROUP BY queries, nothing else.
        var b2 = captured["B2"];
        Assert.Contains("GROUP BY [r].[Status]", b2[0].Text);
        Assert.Contains("GROUP BY [r].[Priority]", b2[1].Text);
        Assert.All(b2, command => Assert.DoesNotContain("WHERE", command.Text));

        var outDirectory = Environment.GetEnvironmentVariable("T501_SQL_OUT");
        if (!string.IsNullOrWhiteSpace(outDirectory))
        {
            Directory.CreateDirectory(outDirectory);
            foreach (var scenario in Scenarios)
            {
                File.WriteAllText(Path.Combine(outDirectory, $"{scenario.Id}.sql"), Render(scenario, captured[scenario.Id]), new UTF8Encoding(false));
            }
        }
    }

    [Fact]
    public async Task Capture_IsDeterministic()
    {
        var first = await CaptureAllAsync();
        var second = await CaptureAllAsync();

        foreach (var scenario in Scenarios)
        {
            Assert.Equal(Render(scenario, first[scenario.Id]), Render(scenario, second[scenario.Id]));
        }
    }

    private static string Iso(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private static async Task<Dictionary<string, List<CapturedCommand>>> CaptureAllAsync()
    {
        var result = new Dictionary<string, List<CapturedCommand>>();
        foreach (var scenario in Scenarios)
        {
            var recorder = new Recorder();
            await using var db = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>()
                .UseSqlServer("Server=unused;Database=unused;Trusted_Connection=True;TrustServerCertificate=True")
                .AddInterceptors(recorder, new SuppressConnectionOpen())
                .Options);
            var service = new RequestQueryService(
                db,
                new StatusTransitionPolicy(),
                TimeProvider.System,
                new RequestSummaryCache(Options.Create(new SummaryCacheOptions()), TimeProvider.System));

            await scenario.Run(service, CancellationToken.None);
            result[scenario.Id] = recorder.Commands;
        }

        return result;
    }

    private static string WhereClause(string sql)
    {
        var where = sql[sql.IndexOf("WHERE", StringComparison.Ordinal)..];
        var end = where.IndexOf("ORDER BY", StringComparison.Ordinal);
        return (end < 0 ? where : where[..end]).Trim();
    }

    private static string Render(Scenario scenario, List<CapturedCommand> commands)
    {
        var commit = Environment.GetEnvironmentVariable("T501_COMMIT") ?? "(not recorded)";
        var sourceState = Environment.GetEnvironmentVariable("T501_SRC_STATE") ?? "(not recorded)";
        var text = new StringBuilder();
        text.Append("-- T-501 captured SQL: the command text and parameters EF Core really builds\n");
        text.Append($"-- scenario: {scenario.Id}\n");
        text.Append($"-- operation: {scenario.Operation}\n");
        text.Append($"-- request: {scenario.Request}\n");
        text.Append($"-- captured from commit: {commit}; backend/src: {sourceState}\n");
        text.Append("-- tool: PerfSqlCaptureTests runs the real RequestQueryService; an EF interceptor records each command and no database is contacted\n");
        text.Append($"-- statements, in execution order: {string.Join(", ", scenario.Parts)}\n");
        text.Append("-- Commands with parameters are written as the EXEC sp_executesql call SqlClient sends: declared types come from the SqlParameter objects EF built\n");
        text.Append("-- (a string with no explicit size is declared nvarchar(4000), or nvarchar(max) above 4,000 characters, as SqlClient does).\n");
        text.Append("-- Line breaks inside the command text are normalised to LF.\n");
        for (var i = 0; i < commands.Count; i++)
        {
            text.Append($"\n-- part: {scenario.Parts[i]}\n");
            text.Append(ToSql(commands[i]));
            text.Append("\nGO\n");
        }

        return text.ToString();
    }

    private static string ToSql(CapturedCommand command)
    {
        var sql = command.Text.Replace("\r\n", "\n", StringComparison.Ordinal).TrimEnd();
        if (command.Parameters.Count == 0)
        {
            return sql + ";";
        }

        var declarations = string.Join(", ", command.Parameters.Select(p => $"{p.Name} {Declare(p)}"));
        var assignments = string.Join(", ", command.Parameters.Select(p => $"{p.Name} = {Literal(p)}"));
        return $"EXEC sp_executesql N'{sql.Replace("'", "''", StringComparison.Ordinal)}', N'{declarations}', {assignments};";
    }

    private static string Declare(CapturedParameter p) => p.SqlDbType switch
    {
        SqlDbType.Int => "int",
        SqlDbType.TinyInt => "tinyint",
        SqlDbType.SmallInt => "smallint",
        SqlDbType.BigInt => "bigint",
        SqlDbType.Bit => "bit",
        SqlDbType.NVarChar => $"nvarchar({StringSize(p)})",
        SqlDbType.DateTime2 => $"datetime2({(p.Scale == 0 ? 7 : p.Scale)})",
        _ => throw new NotSupportedException($"Parameter {p.Name} has the unsupported type {p.SqlDbType}."),
    };

    private static string StringSize(CapturedParameter p)
    {
        if (p.Size > 0)
        {
            return p.Size.ToString(CultureInfo.InvariantCulture);
        }

        return p.Value is string { Length: > 4000 } ? "max" : "4000";
    }

    private static string Literal(CapturedParameter p) => p.Value switch
    {
        null or DBNull => "NULL",
        string s => $"N'{s.Replace("'", "''", StringComparison.Ordinal)}'",
        bool b => b ? "1" : "0",
        DateTime d => $"'{d.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff", CultureInfo.InvariantCulture)}'",
        Enum e => Convert.ToInt64(e, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture),
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => throw new NotSupportedException($"Parameter {p.Name} has the unsupported value type {p.Value.GetType()}."),
    };

    private sealed record Scenario(
        string Id,
        string Operation,
        string Request,
        Func<RequestQueryService, CancellationToken, Task> Run,
        string[] Parts);

    private sealed record CapturedParameter(string Name, SqlDbType SqlDbType, int Size, byte Scale, object? Value);

    private sealed record CapturedCommand(string Text, IReadOnlyList<CapturedParameter> Parameters)
    {
        public static CapturedCommand From(DbCommand command) => new(
            command.CommandText,
            command.Parameters.Cast<SqlParameter>()
                .Select(p => new CapturedParameter(p.ParameterName.StartsWith('@') ? p.ParameterName : "@" + p.ParameterName, p.SqlDbType, p.Size, p.Scale, p.Value))
                .ToList());
    }

    /// <summary>Records every command and answers it with a canned result: one int (100,000) for a COUNT, no rows otherwise.</summary>
    private sealed class Recorder : DbCommandInterceptor
    {
        public List<CapturedCommand> Commands { get; } = [];

        public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            Commands.Add(CapturedCommand.From(command));

            var table = new DataTable();
            if (command.CommandText.TrimStart().StartsWith("SELECT COUNT(*)", StringComparison.Ordinal))
            {
                table.Columns.Add("Count", typeof(int));
                table.Rows.Add(100_000);
            }

            return ValueTask.FromResult(InterceptionResult<DbDataReader>.SuppressWithResult(table.CreateDataReader()));
        }
    }

    private sealed class SuppressConnectionOpen : DbConnectionInterceptor
    {
        public override ValueTask<InterceptionResult> ConnectionOpeningAsync(
            DbConnection connection, ConnectionEventData eventData, InterceptionResult result, CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(InterceptionResult.Suppress());
    }
}
