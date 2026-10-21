using System.Globalization;
using Microsoft.Data.SqlClient;
using RequestManagement.Infrastructure.Seeding;

namespace RequestManagement.Seeder;

/// <summary>Parsed command line. Unknown or malformed arguments are errors, never ignored.</summary>
internal sealed record SeederArguments(SeedOptions Options, bool Reset, bool ShowHelp)
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
          --help             Show this text.

        Requirements:
          DOTNET_ENVIRONMENT=Development (the tool refuses to run otherwise).
          Connection string 'ConnectionStrings:RequestManagement' from user-secrets
          or the ConnectionStrings__RequestManagement environment variable.

        Without --reset the database must be fully migrated and empty.
        """;

    public static bool TryParse(string[] args, out SeederArguments result, out string? error)
    {
        var options = new SeedOptions();
        var reset = false;
        var help = false;
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

        result = new SeederArguments(options, reset, help);
        return error is null;
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
