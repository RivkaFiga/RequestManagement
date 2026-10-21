using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using RequestManagement.Core.Domain;
using RequestManagement.Infrastructure.Persistence;

namespace RequestManagement.UnitTests;

/// <summary>
/// Checks the EF Core mapping without a database: building the model needs no connection.
/// </summary>
public sealed class AppDbContextModelTests : IDisposable
{
    private readonly AppDbContext _db = new DesignTimeDbContextFactory().CreateDbContext([]);

    public void Dispose() => _db.Dispose();

    private IRelationalModel RelationalModel =>
        _db.GetService<IDesignTimeModel>().Model.GetRelationalModel();

    [Fact]
    public void Migrations_AreInSyncWithTheModel()
    {
        // Fails if the mapping changed without a new migration.
        Assert.False(_db.Database.HasPendingModelChanges());
    }

    [Fact]
    public void Requests_ColumnsHaveTheExpectedStoreTypes()
    {
        var table = RelationalModel.FindTable("Requests", null)!;
        string StoreType(string column) => table.FindColumn(column)!.StoreType;

        Assert.Equal("int", StoreType("Id"));
        Assert.Equal("nvarchar(200)", StoreType("Title"));
        Assert.Equal("nvarchar(200)", StoreType("OrganizationName"));
        Assert.Equal("tinyint", StoreType("Status"));
        Assert.Equal("tinyint", StoreType("Priority"));
        Assert.Equal("nvarchar(100)", StoreType("AssignedTo"));
        Assert.Equal("datetime2(3)", StoreType("CreatedAt"));
        Assert.Equal("datetime2(3)", StoreType("UpdatedAt"));
        Assert.Equal("rowversion", StoreType("Version"));

        Assert.True(table.FindColumn("AssignedTo")!.IsNullable);
        Assert.False(table.FindColumn("Title")!.IsNullable);
        Assert.False(table.FindColumn("OrganizationName")!.IsNullable);
    }

    [Fact]
    public void Version_IsADatabaseGeneratedConcurrencyToken()
    {
        var version = _db.Model.FindEntityType(typeof(Request))!.FindProperty(nameof(Request.Version))!;

        Assert.True(version.IsConcurrencyToken);
        Assert.Equal(ValueGenerated.OnAddOrUpdate, version.ValueGenerated);
    }

    [Fact]
    public void History_ReferencesRequestWithoutCascadeDelete()
    {
        var foreignKey = Assert.Single(_db.Model.FindEntityType(typeof(RequestStatusHistoryEntry))!.GetForeignKeys());

        Assert.Equal(typeof(Request), foreignKey.PrincipalEntityType.ClrType);
        Assert.Equal(nameof(RequestStatusHistoryEntry.RequestId), Assert.Single(foreignKey.Properties).Name);
        Assert.Equal(DeleteBehavior.Restrict, foreignKey.DeleteBehavior);
        Assert.True(foreignKey.IsRequired);
    }

    [Fact]
    public void History_ColumnsHaveTheExpectedStoreTypes()
    {
        var table = RelationalModel.FindTable("RequestStatusHistory", null)!;

        Assert.Equal("bigint", table.FindColumn("Id")!.StoreType);
        Assert.Equal("tinyint", table.FindColumn("PreviousStatus")!.StoreType);
        Assert.Equal("tinyint", table.FindColumn("NewStatus")!.StoreType);
        Assert.Equal("datetime2(3)", table.FindColumn("ChangedAt")!.StoreType);
        Assert.Equal("nvarchar(100)", table.FindColumn("ChangedBy")!.StoreType);
        Assert.False(table.FindColumn("ChangedBy")!.IsNullable);
    }

    [Fact]
    public void CheckConstraints_AreDefined()
    {
        var names = _db.GetService<IDesignTimeModel>().Model.GetEntityTypes()
            .SelectMany(e => e.GetCheckConstraints())
            .Select(c => (string?)c.Name)
            .ToList();

        string[] expected =
        [
            "CK_Requests_Status",
            "CK_Requests_Priority",
            "CK_Requests_UpdatedAt_NotBeforeCreatedAt",
            "CK_RequestStatusHistory_PreviousStatus",
            "CK_RequestStatusHistory_NewStatus",
            "CK_RequestStatusHistory_StatusChanged",
        ];
        foreach (var name in expected)
        {
            Assert.Contains(name, names);
        }
    }

    [Fact]
    public void Indexes_MatchThePlannedQueryPatterns()
    {
        var requestIndexes = _db.Model.FindEntityType(typeof(Request))!.GetIndexes()
            .ToDictionary(i => i.GetDatabaseName()!, i => string.Join(",", i.Properties.Select(p => p.Name)));
        var historyIndexes = _db.Model.FindEntityType(typeof(RequestStatusHistoryEntry))!.GetIndexes()
            .ToDictionary(i => i.GetDatabaseName()!, i => string.Join(",", i.Properties.Select(p => p.Name)));

        Assert.Equal(
            new Dictionary<string, string>
            {
                ["IX_Requests_CreatedAt_Id"] = "CreatedAt,Id",
                ["IX_Requests_Status_CreatedAt"] = "Status,CreatedAt",
                ["IX_Requests_AssignedTo_Status_CreatedAt"] = "AssignedTo,Status,CreatedAt",
                ["IX_Requests_OrganizationName_CreatedAt"] = "OrganizationName,CreatedAt",
                ["IX_Requests_Priority_Status"] = "Priority,Status",
            },
            requestIndexes);
        Assert.Equal(
            new Dictionary<string, string> { ["IX_RequestStatusHistory_RequestId_ChangedAt"] = "RequestId,ChangedAt" },
            historyIndexes);
    }
}
