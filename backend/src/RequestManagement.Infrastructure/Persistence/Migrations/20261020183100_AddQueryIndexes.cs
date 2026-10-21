using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace RequestManagement.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    /// <remarks>
    /// Kept separate from InitialCreate (decision D14) so the performance work can measure the
    /// same data with and without these indexes: `dotnet ef database update InitialCreate`
    /// removes them, `dotnet ef database update` re-applies them.
    /// </remarks>
    public partial class AddQueryIndexes : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateIndex(
                name: "IX_Requests_AssignedTo_Status_CreatedAt",
                table: "Requests",
                columns: new[] { "AssignedTo", "Status", "CreatedAt" },
                descending: new[] { false, false, true });

            migrationBuilder.CreateIndex(
                name: "IX_Requests_CreatedAt_Id",
                table: "Requests",
                columns: new[] { "CreatedAt", "Id" },
                descending: new[] { true, true });

            migrationBuilder.CreateIndex(
                name: "IX_Requests_OrganizationName_CreatedAt",
                table: "Requests",
                columns: new[] { "OrganizationName", "CreatedAt" },
                descending: new[] { false, true });

            migrationBuilder.CreateIndex(
                name: "IX_Requests_Priority_Status",
                table: "Requests",
                columns: new[] { "Priority", "Status" });

            migrationBuilder.CreateIndex(
                name: "IX_Requests_Status_CreatedAt",
                table: "Requests",
                columns: new[] { "Status", "CreatedAt" },
                descending: new[] { false, true })
                .Annotation("SqlServer:Include", new[] { "Priority" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Requests_AssignedTo_Status_CreatedAt",
                table: "Requests");

            migrationBuilder.DropIndex(
                name: "IX_Requests_CreatedAt_Id",
                table: "Requests");

            migrationBuilder.DropIndex(
                name: "IX_Requests_OrganizationName_CreatedAt",
                table: "Requests");

            migrationBuilder.DropIndex(
                name: "IX_Requests_Priority_Status",
                table: "Requests");

            migrationBuilder.DropIndex(
                name: "IX_Requests_Status_CreatedAt",
                table: "Requests");
        }
    }
}
