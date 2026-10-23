using System.Globalization;
using Microsoft.Data.SqlClient;
using RequestManagement.Infrastructure.Seeding;

namespace RequestManagement.Seeder;

/// <summary>Parsed command line. Unknown or malformed arguments are errors, never ignored.</summary>
internal sealed record SeederArguments(
    SeedOptions Options,
    bool Reset,
    bool ShowHelp,
    bool CreateNew = false,
    string? ExpectServer = null,
    string? ExpectDatabase = null)
{
    public const string Usage =
        """
        Generates deterministic test data for the development database.

        Usage:
          dotnet run --project src/RequestManagement.Seeder -- [options]

        Options:
          --count <n>        Requests to generate (default 100000, max 5000000)
          --batch-size <n>   Rows per bulk-copy batch (default 10000, range 100-100000)
          --seed <n>         Random seed (default 20261020). Same seed => same data.
          --reset            DESTRUCTIVE: drop the database, re-apply all migrations, then seed.
          --create-new       Create the database and seed it. Refuses if the database already exists;
                             never drops anything. Needs --expect-server and --expect-database.
          --expect-server <s>    Refuse to run unless the server is exactly <s> (case-sensitive).
          --expect-database <d>  Refuse to run unless the database is exactly <d> (case-sensitive).
                                 With either option the connection string must be set in the
                                 ConnectionStrings__RequestManagement environment variable
                                 (user-secrets are not accepted).
          --help             Show this text.

        Requirements:
          DOTNET_ENVIRONMENT=Development (the tool refuses to run otherwise).
          Connection string 'ConnectionStrings:RequestManagement' from user-secrets
          or the ConnectionStrings__RequestManagement environment variable.

        Without --reset or --create-new the database must be fully migrated and empty.
        """;

    public static bool TryParse(string[] args, out SeederArguments result, out string? error)
    {
        var options = new SeedOptions();
        var reset = false;
        var help = false;
        var createNew = false;
        string? expectServer = null;
        string? expectDatabase = null;
        error = null;

        for (var i = 0; i < args.Length && error is null; i++)
        {
            switch (args[i])
            {
                case "--count":
                    options = options with { Count = ReadInt(args, ref i, ref error) };
                    break;
                case "--batch-size":
                    options = options with { BatchSize = ReadInt(args, ref i, ref error) };
                    break;
                case "--seed":
                    options = options with { RandomSeed = ReadInt(args, ref i, ref error) };
                    break;
                case "--reset":
                    reset = true;
                    break;
                case "--create-new":
                    createNew = true;
                    break;
                case "--expect-server":
                    expectServer = ReadString(args, ref i, ref error);
                    break;
                case "--expect-database":
                    expectDatabase = ReadString(args, ref i, ref error);
                    break;
                case "--help" or "-h":
                    help = true;
                    break;
                default:
                    error = $"Unknown argument '{args[i]}'.";
                    break;
            }
        }

        if (error is null && !help)
        {
            try
            {
                options.Validate();
            }
            catch (ArgumentException ex)
            {
                error = ex.Message;
            }
        }

        if (error is null && !help)
        {
            if (createNew && reset)
            {
                error = "--create-new and --reset are mutually exclusive.";
            }
            else if ((expectServer is null) != (expectDatabase is null))
            {
                error = "--expect-server and --expect-database must be given together.";
            }
            else if (createNew && expectDatabase is null)
            {
                error = "--create-new requires --expect-server and --expect-database.";
            }
        }

        result = new SeederArguments(options, reset, help, createNew, expectServer, expectDatabase);
        return error is null;
    }

    /// <summary>
    /// When an expected target was given, the connection string must be the one in the process environment
    /// (never user-secrets). Without expectations nothing changes.
    /// </summary>
    public static string? CheckExplicitEnvironmentVariable(SeederArguments arguments, string? environmentValue, string? configuredValue)
    {
        if (arguments.ExpectDatabase is null)
        {
            return null;
        }

        if (string.IsNullOrWhiteSpace(environmentValue))
        {
            return "Refusing to run: ConnectionStrings__RequestManagement is not set in the process environment " +
                   "(the connection string would come from user-secrets).";
        }

        return string.Equals(environmentValue, configuredValue, StringComparison.Ordinal)
            ? null
            : "Refusing to run: the connection string in use is not the one in ConnectionStrings__RequestManagement.";
    }

    /// <summary>Server and database must equal the expected values exactly (ordinal, case-sensitive).</summary>
    public static string? CheckExpectedTarget(SeederArguments arguments, SqlConnectionStringBuilder connection)
    {
        if (arguments.ExpectServer is null || arguments.ExpectDatabase is null)
        {
            return null;
        }

        if (!string.Equals(connection.DataSource, arguments.ExpectServer, StringComparison.Ordinal))
        {
            return $"Refusing to run: server is '{connection.DataSource}', expected exactly '{arguments.ExpectServer}'.";
        }

        return string.Equals(connection.InitialCatalog, arguments.ExpectDatabase, StringComparison.Ordinal)
            ? null
            : $"Refusing to run: database is '{connection.InitialCatalog}', expected exactly '{arguments.ExpectDatabase}'.";
    }

    /// <summary>
    /// The seeder writes test data and can drop the database, so it only runs in the
    /// Development environment and never against a system database.
    /// </summary>
    public static string? CheckSafety(string? environmentName, SqlConnectionStringBuilder connection)
    {
        if (!string.Equals(environmentName, "Development", StringComparison.OrdinalIgnoreCase))
        {
            return $"Refusing to run: DOTNET_ENVIRONMENT is '{environmentName ?? "(not set)"}'. " +
                   "The seeder writes test data and --reset drops the database, so it runs only with DOTNET_ENVIRONMENT=Development.";
        }

        var database = connection.InitialCatalog;
        if (string.IsNullOrWhiteSpace(database))
        {
            return "Refusing to run: the connection string does not name a database (Database=...).";
        }

        if (database.ToLowerInvariant() is "master" or "model" or "msdb" or "tempdb")
        {
            return $"Refusing to run against the system database '{database}'.";
        }

        return null;
    }

    private static string? ReadString(string[] args, ref int index, ref string? error)
    {
        var name = args[index];
        if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]) || args[index + 1].StartsWith("--", StringComparison.Ordinal))
        {
            error = $"{name} requires a value.";
            return null;
        }

        index++;
        return args[index];
    }

    private static int ReadInt(string[] args, ref int index, ref string? error)
    {
        var name = args[index];
        if (index + 1 >= args.Length
            || !int.TryParse(args[index + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
        {
            error = $"{name} requires an integer value.";
            return 0;
        }

        index++;
        return value;
    }
}
