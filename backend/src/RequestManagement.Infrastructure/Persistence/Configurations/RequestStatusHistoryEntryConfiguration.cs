using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using RequestManagement.Core.Domain;

namespace RequestManagement.Infrastructure.Persistence.Configurations;

internal sealed class RequestStatusHistoryEntryConfiguration : IEntityTypeConfiguration<RequestStatusHistoryEntry>
{
    public void Configure(EntityTypeBuilder<RequestStatusHistoryEntry> builder)
    {
        builder.ToTable("RequestStatusHistory", table =>
        {
            table.HasCheckConstraint("CK_RequestStatusHistory_PreviousStatus", "[PreviousStatus] BETWEEN 1 AND 4");
            table.HasCheckConstraint("CK_RequestStatusHistory_NewStatus", "[NewStatus] BETWEEN 1 AND 4");
            table.HasCheckConstraint("CK_RequestStatusHistory_StatusChanged", "[PreviousStatus] <> [NewStatus]");
        });

        builder.HasKey(h => h.Id);

        builder.Property(h => h.ChangedBy).HasMaxLength(RequestStatusHistoryEntry.ChangedByMaxLength);

        // "History of request X, newest first". Also serves as the FK index on RequestId,
        // so EF Core does not create a separate one.
        builder.HasIndex(h => new { h.RequestId, h.ChangedAt }, "IX_RequestStatusHistory_RequestId_ChangedAt")
            .IsDescending(false, true);
    }
}
