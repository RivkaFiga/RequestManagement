using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.IntegrationTests;

/// <summary>
/// T-201 (QC-4, QC-6, QC-8, R10.4, R10.6, D13): the API skeleton, hosted in-process. No test here touches a database:
/// the connection string is never used, because the services that would use it are replaced or never called.
/// </summary>
public sealed class ApiFoundationTests
{
    private const string NoDatabase = "Server=unused;Database=unused;Trusted_Connection=True;TrustServerCertificate=True";

    /// <summary>Makes the middleware's debug messages visible, so a test can see who handled an aborted request.</summary>
    private static readonly Dictionary<string, string?> DiagnosticsDebug = new()
    {
        ["Logging:LogLevel:Microsoft.AspNetCore.Diagnostics"] = "Debug",
    };

    // ---------------------------------------------------------------- unhandled errors

    [Fact]
    public async Task UnhandledException_Returns500ProblemDetails_WithoutInternals_AndIsLoggedAsError()
    {
        const string Secret = "SECRET-INTERNAL-DETAIL";
        var logs = new LogCapture();
        using var factory = Factory(logs, new FailingQueryService(new InvalidOperationException(Secret)));
        using var client = factory.CreateClient();

        using var response = await client.GetAsync("/api/requests");

        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadAsStringAsync();
        var problem = JsonDocument.Parse(body).RootElement;
        Assert.Equal(500, problem.GetProperty("status").GetInt32());
        Assert.False(string.IsNullOrWhiteSpace(problem.GetProperty("title").GetString()));
        Assert.True(problem.TryGetProperty("traceId", out _));

        // Nothing about the exception reaches the client: no message, type, stack trace or source location.
        Assert.DoesNotContain(Secret, body);
        Assert.DoesNotContain(nameof(InvalidOperationException), body);
        Assert.DoesNotContain(nameof(FailingQueryService), body);
        Assert.DoesNotContain("stackTrace", body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("exception", body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(".cs:line", body);

        // The detail stays on the server (QC-8).
        Assert.Contains(logs.Entries, e => e.Level == LogLevel.Error && e.Exception?.Message == Secret);
    }

    [Fact]
    public async Task ClientAbort_IsNotLoggedAsError_AndIsHandledByAspNetCore_NotByTheGlobalHandler()
    {
        var logs = new LogCapture();
        var service = new FailingQueryService(searchWaitsForCancellation: true);
        using var factory = Factory(logs, service, DiagnosticsDebug);
        using var client = factory.CreateClient();
        using var abort = new CancellationTokenSource();

        var call = client.GetAsync("/api/requests", abort.Token);
        await service.SearchStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await abort.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);

        // The server finishes the request after the client has gone; wait for the middleware's own message.
        await logs.WaitForAsync(e => e.Message.Contains("aborted by the client", StringComparison.OrdinalIgnoreCase));

        Assert.DoesNotContain(logs.Entries, e => e.Level >= LogLevel.Warning);
        Assert.DoesNotContain(logs.Entries, e => e.Category.EndsWith("GlobalExceptionHandler", StringComparison.Ordinal));
    }

    // ---------------------------------------------------------------- OpenAPI and Swagger UI (D13)

    [Theory]
    [InlineData("Development", HttpStatusCode.OK)]
    [InlineData("Production", HttpStatusCode.NotFound)]
    [InlineData("Staging", HttpStatusCode.NotFound)]
    public async Task OpenApiAndSwaggerUi_AreServedInDevelopmentOnly(string environment, HttpStatusCode expected)
    {
        using var factory = new ApiFactory(NoDatabase).WithWebHostBuilder(builder => builder.UseEnvironment(environment));
        using var client = factory.CreateClient();

        foreach (var path in new[] { "/openapi/v1.json", "/swagger/index.html" })
        {
            using var response = await client.GetAsync(path);
            Assert.True(expected == response.StatusCode, $"{environment} {path}: expected {expected}, got {response.StatusCode}.");
        }
    }

    // ---------------------------------------------------------------- DI validation (QC-4)

    [Fact]
    public void Development_ValidatesScopesAndTheServiceGraphAtStartup()
    {
        using var development = new ApiFactory(NoDatabase, null, services => services.AddSingleton<CaptiveDependency>())
            .WithWebHostBuilder(builder => builder.UseEnvironment("Development"));

        // A singleton that takes a scoped service (the DbContext) must stop the app from starting.
        var failure = Assert.ThrowsAny<Exception>(() => development.CreateClient());
        Assert.Contains("Cannot consume scoped service", failure.ToString());

        // The same registration starts in Production, so the failure above comes from the Development defaults.
        using var production = new ApiFactory(NoDatabase, null, services => services.AddSingleton<CaptiveDependency>())
            .WithWebHostBuilder(builder => builder.UseEnvironment("Production"));
        using var client = production.CreateClient();
        Assert.NotNull(client);
    }

    // ---------------------------------------------------------------- helpers

    private static ApiFactory Factory(LogCapture logs, IRequestQueryService queryService, IReadOnlyDictionary<string, string?>? settings = null) =>
        new(NoDatabase, settings, services =>
        {
            services.AddSingleton<ILoggerProvider>(logs);
            services.AddScoped(_ => queryService);
        });

    /// <summary>A singleton with a scoped dependency, which the DI container must refuse in Development.</summary>
    private sealed class CaptiveDependency(AppDbContext db)
    {
        public AppDbContext Db { get; } = db;
    }

    private sealed class FailingQueryService : IRequestQueryService
    {
        private readonly Exception? _failure;
        private readonly bool _searchWaitsForCancellation;

        public FailingQueryService(Exception failure) => _failure = failure;

        public FailingQueryService(bool searchWaitsForCancellation) => _searchWaitsForCancellation = searchWaitsForCancellation;

        public TaskCompletionSource SearchStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<PagedResult<RequestDto>> SearchAsync(RequestSearchQuery query, CancellationToken ct)
        {
            if (_searchWaitsForCancellation)
            {
                SearchStarted.TrySetResult();
                await Task.Delay(Timeout.Infinite, ct);
            }

            throw _failure!;
        }

        public Task<RequestDto?> GetByIdAsync(int id, CancellationToken ct) => throw new NotSupportedException();

        public Task<IReadOnlyList<StatusHistoryEntryDto>?> GetHistoryAsync(int id, CancellationToken ct) => throw new NotSupportedException();

        public Task<RequestSummaryDto> GetSummaryAsync(CancellationToken ct) => throw new NotSupportedException();
    }

    private sealed record LogEntry(string Category, LogLevel Level, string Message, Exception? Exception);

    private sealed class LogCapture : ILoggerProvider
    {
        private readonly ConcurrentQueue<LogEntry> _entries = new();

        public IReadOnlyCollection<LogEntry> Entries => _entries;

        public ILogger CreateLogger(string categoryName) => new CaptureLogger(categoryName, _entries);

        public async Task WaitForAsync(Func<LogEntry, bool> predicate)
        {
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (!_entries.Any(predicate))
            {
                Assert.True(DateTime.UtcNow < deadline, "The expected log entry did not appear within 10 seconds.");
                await Task.Delay(25);
            }
        }

        public void Dispose()
        {
        }

        private sealed class CaptureLogger(string category, ConcurrentQueue<LogEntry> entries) : ILogger
        {
            public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

            public bool IsEnabled(LogLevel logLevel) => true;

            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) =>
                entries.Enqueue(new LogEntry(category, logLevel, formatter(state, exception), exception));
        }
    }
}
