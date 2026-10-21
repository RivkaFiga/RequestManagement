using RequestManagement.Core.Domain;

namespace RequestManagement.Infrastructure.Seeding;

/// <summary>
/// Produces a deterministic, lazily generated stream of requests. Nothing is buffered:
/// callers decide how many rows to hold in memory at once.
/// </summary>
/// <remarks>
/// Determinism comes from a seeded <see cref="Random"/> consumed in a fixed order and a fixed
/// anchor date (never the clock). Ids are assigned 1..count.
/// </remarks>
public static class SeedDataGenerator
{
    internal const int HandlerCount = 50;
    internal const int UnassignedPercent = 15;
    internal const int HistoryWindowDays = 730; // about 24 months

    private static readonly string[] OrganizationPrefixes =
    [
        "Aurora", "Beacon", "Cedar", "Delta", "Ember", "Falcon", "Granite", "Harbor", "Iris", "Juniper",
        "Keystone", "Lumen", "Meridian", "Northgate", "Oakridge", "Pioneer", "Quartz", "Riverside", "Summit", "Tidewater",
        "Unity", "Vantage", "Westfield", "Zenith", "Atlas", "Bluewater", "Crescent", "Driftwood", "Evergreen", "Frontier",
        "Goldleaf", "Highland", "Ironwood", "Jasper", "Kingsbridge", "Lakeside", "Maple", "Nova", "Orchard", "Pinecrest",
    ];

    private static readonly string[] OrganizationKinds =
    [
        "Logistics", "Health Services", "Municipality", "Engineering", "Insurance",
        "Education Center", "Water Authority", "Credit Union", "Hospital", "Transport",
        "Energy", "Housing Association", "Libraries", "Manufacturing", "Retail Group",
        "Telecom", "Consulting", "Food Supply", "Medical Clinic", "Legal Services",
        "Construction", "Software", "Pharmacy", "Security", "Printing",
        "Shipping", "Textiles", "Farming Cooperative", "Tourism Board", "Archives",
        "Auto Parts", "Electronics", "Furniture", "Packaging", "Recycling",
        "Research Institute", "Laboratories", "Media", "Finance", "Travel",
        "Catering", "Cleaning Services", "Maintenance", "Utilities", "Port Authority",
        "Rail", "Aviation", "Chemicals", "Paper Mill", "Steelworks",
    ];

    private static readonly string[] TitleActions =
    [
        "Reset password for", "Request access to", "Report outage in", "Update billing details in", "Renew license for",
        "Install update on", "Fix login issue in", "Migrate data from", "Configure backup for", "Replace hardware for",
        "Review invoice for", "Extend storage for", "Investigate slowness in", "Remove user from", "Add user to",
        "Restore files in", "Upgrade plan for", "Audit permissions in", "Schedule maintenance for", "Close account in",
    ];

    private static readonly string[] TitleSubjects =
    [
        "billing portal", "email server", "customer database", "payroll system", "VPN gateway",
        "file share", "printer fleet", "CRM workspace", "inventory module", "support mailbox",
        "HR portal", "reporting dashboard", "warehouse scanner", "phone system", "web shop",
        "document archive", "time tracking app", "accounting ledger", "mobile app", "backup server",
        "intranet site", "shipping labels", "contract registry", "analytics cluster", "door access system",
    ];

    /// <summary>~2,000 distinct organization names (prefix × kind).</summary>
    internal static int OrganizationCount => OrganizationPrefixes.Length * OrganizationKinds.Length;

    public static IEnumerable<Request> Generate(SeedOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();
        return GenerateCore(options);
    }

    private static IEnumerable<Request> GenerateCore(SeedOptions options)
    {
        var random = new Random(options.RandomSeed);
        var anchor = options.AnchorUtc;
        var windowMs = (long)TimeSpan.FromDays(HistoryWindowDays).TotalMilliseconds;

        for (var id = 1; id <= options.Count; id++)
        {
            // The order of the random draws below is part of the data contract:
            // changing it changes every generated row.
            var title = $"{Pick(random, TitleActions)} {Pick(random, TitleSubjects)}";
            var organization = PickOrganization(random);
            var status = PickStatus(random);
            var priority = PickPriority(random);
            var assignedTo = random.Next(100) < UnassignedPercent
                ? null
                : $"handler-{random.Next(1, HandlerCount + 1):D2}";

            var createdAt = anchor.AddMilliseconds(-random.NextInt64(1, windowMs + 1));
            var updatedAt = status == RequestStatus.New
                ? createdAt
                : createdAt.AddMilliseconds(random.NextInt64(0, (long)(anchor - createdAt).TotalMilliseconds + 1));

            yield return new Request
            {
                Id = id,
                Title = title,
                OrganizationName = organization,
                Status = status,
                Priority = priority,
                AssignedTo = assignedTo,
                CreatedAt = createdAt,
                UpdatedAt = updatedAt,
            };
        }
    }

    private static string Pick(Random random, string[] values) => values[random.Next(values.Length)];

    private static string PickOrganization(Random random)
    {
        // Squaring skews towards low indexes: a few large organizations, a long tail of small ones.
        var index = (int)(Math.Pow(random.NextDouble(), 2) * OrganizationCount);
        return $"{OrganizationPrefixes[index / OrganizationKinds.Length]} {OrganizationKinds[index % OrganizationKinds.Length]}";
    }

    // Skewed distributions: New 20%, InProgress 30%, Waiting 15%, Completed 35%.
    private static RequestStatus PickStatus(Random random) => random.Next(100) switch
    {
        < 20 => RequestStatus.New,
        < 50 => RequestStatus.InProgress,
        < 65 => RequestStatus.Waiting,
        _ => RequestStatus.Completed,
    };

    // Low 40%, Medium 45%, High 15%.
    private static RequestPriority PickPriority(Random random) => random.Next(100) switch
    {
        < 40 => RequestPriority.Low,
        < 85 => RequestPriority.Medium,
        _ => RequestPriority.High,
    };
}
