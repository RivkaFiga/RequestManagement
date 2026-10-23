using System.Diagnostics;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Seeding;
using RequestManagement.Seeder;

if (!SeederArguments.TryParse(args, out var arguments, out var argumentError))
{
    Console.Error.WriteLine(argumentError);
    Console.Error.WriteLine("Run with --help for usage.");
    return 2;
}

if (arguments.ShowHelp)
{
    Console.WriteLine(SeederArguments.Usage);
    return 0;
}

var environmentName = Environment.GetEnvironmentVariable("DOTNET_ENVIRONMENT");
var configuration = new ConfigurationBuilder()
    .AddUserSecrets(typeof(SeederArguments).Assembly, optional: true)
    .AddEnvironmentVariables()
    .Build();

var connectionString = configuration.GetConnectionString("RequestManagement");
if (string.IsNullOrWhiteSpace(connectionString))
{
    Console.Error.WriteLine(
        "Connection string 'RequestManagement' not found. Set it with user-secrets or the " +
        "ConnectionStrings__RequestManagement environment variable (see README).");
    return 2;
}

SqlConnectionStringBuilder target;
try
{
    target = new SqlConnectionStringBuilder(connectionString);
}
catch (ArgumentException)
{
    Console.Error.WriteLine("The connection string 'RequestManagement' is malformed.");
    return 2;
}

var safetyError = SeederArguments.CheckSafety(environmentName, target);
if (safetyError is not null)
{
    Console.Error.WriteLine(safetyError);
    return 3;
}

// With --expect-server / --expect-database: the connection string must come from the process environment and
// name exactly the expected server and database. Checked before any connection is opened.
var targetError = SeederArguments.CheckExplicitEnvironmentVariable(
        arguments, Environment.GetEnvironmentVariable("ConnectionStrings__RequestManagement"), connectionString)
    ?? SeederArguments.CheckExpectedTarget(arguments, target);
if (targetError is not null)
{
    Console.Error.WriteLine(targetError);
    return 3;
}

using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    cancellation.Cancel();
};

// Only the server and database are printed; never the full connection string.
Console.WriteLine($"Target: server '{target.DataSource}', database '{target.InitialCatalog}'.");

var dbOptions = new DbContextOptionsBuilder<AppDbContext>()
    .UseSqlServer(connectionString, sql => sql.CommandTimeout(300))
    .Options;

try
{
    await using var db = new AppDbContext(dbOptions);

    // The DbContext that runs every command must itself point at the expected target (no connection is opened here).
    var contextError = SeederArguments.CheckExpectedTarget(arguments, new SqlConnectionStringBuilder(db.Database.GetConnectionString()));
    if (contextError is not null)
    {
        Console.Error.WriteLine(contextError);
        return 3;
    }

    var seeder = new DatabaseSeeder(db);
    var options = arguments.Options;

    if (arguments.CreateNew)
    {
        if (await DatabaseExistsAsync(target, cancellation.Token))
        {
            Console.Error.WriteLine(
                $"Refusing to run: database '{target.InitialCatalog}' already exists. --create-new only creates a database " +
                "that does not exist; it never resets or seeds an existing one.");
            return 4;
        }

        Console.WriteLine($"--create-new: database '{target.InitialCatalog}' does not exist; creating it and applying all migrations...");
        await seeder.CreateDatabaseAsync(cancellation.Token);
    }
    else if (arguments.Reset)
    {
        Console.WriteLine($"--reset: dropping database '{target.InitialCatalog}' and re-applying all migrations...");
        await seeder.ResetDatabaseAsync(cancellation.Token);
    }

    Console.WriteLine($"Seeding {options.Count:N0} requests (seed {options.RandomSeed}, batch size {options.BatchSize:N0})...");
    var stopwatch = Stopwatch.StartNew();
    var inserted = await seeder.SeedAsync(options, new ConsoleProgress(), cancellation.Token);
    stopwatch.Stop();

    var report = await seeder.GetReportAsync(cancellation.Token);
    Console.WriteLine($"Inserted {inserted:N0} rows in {stopwatch.Elapsed.TotalSeconds:F1} s.");
    Console.WriteLine($"Requests: {report.RequestCount:N0}   History rows: {report.HistoryCount:N0}");
    Console.WriteLine("By status:   " + string.Join(", ", report.ByStatus.OrderBy(p => p.Key).Select(p => $"{p.Key}={p.Value:N0}")));
    Console.WriteLine("By priority: " + string.Join(", ", report.ByPriority.OrderBy(p => p.Key).Select(p => $"{p.Key}={p.Value:N0}")));
    Console.WriteLine($"Checksum: {report.Checksum}");
    return 0;
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("Cancelled. Uncommitted seed data was rolled back.");
    return 130;
}
catch (InvalidOperationException ex)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}
catch (SqlException ex)
{
    Console.Error.WriteLine($"SQL Server error {ex.Number}: {ex.Message}");
    return 1;
}

/// <summary>Read-only existence check against master of the same server; nothing is created or changed.</summary>
static async Task<bool> DatabaseExistsAsync(SqlConnectionStringBuilder target, CancellationToken cancellationToken)
{
    var master = new SqlConnectionStringBuilder(target.ConnectionString) { InitialCatalog = "master" };
    await using var connection = new SqlConnection(master.ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    command.CommandText = "SELECT COUNT(*) FROM sys.databases WHERE name = @name";
    command.Parameters.AddWithValue("@name", target.InitialCatalog);
    return (int)(await command.ExecuteScalarAsync(cancellationToken))! != 0;
}

/// <summary>Reports synchronously so progress lines never interleave with the final summary.</summary>
internal sealed class ConsoleProgress : IProgress<int>
{
    public void Report(int value) => Console.WriteLine($"  {value:N0} rows written");
}
