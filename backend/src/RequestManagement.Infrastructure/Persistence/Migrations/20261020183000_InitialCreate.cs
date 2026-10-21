using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace RequestManagement.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "Requests",
                columns: table => new
                {
                    Id = table.Column<int>(type: "int", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    Title = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    OrganizationName = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    Status = table.Column<byte>(type: "tinyint", nullable: false),
                    Priority = table.Column<byte>(type: "tinyint", nullable: false),
                    AssignedTo = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: true),
                    CreatedAt = table.Column<DateTime>(type: "datetime2(3)", precision: 3, nullable: false),
                    UpdatedAt = table.Column<DateTime>(type: "datetime2(3)", precision: 3, nullable: false),
                    Version = table.Column<byte[]>(type: "rowversion", rowVersion: true, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Requests", x => x.Id);
                    table.CheckConstraint("CK_Requests_Priority", "[Priority] BETWEEN 1 AND 3");
                    table.CheckConstraint("CK_Requests_Status", "[Status] BETWEEN 1 AND 4");
                    table.CheckConstraint("CK_Requests_UpdatedAt_NotBeforeCreatedAt", "[UpdatedAt] >= [CreatedAt]");
                });

            migrationBuilder.CreateTable(
                name: "RequestStatusHistory",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    RequestId = table.Column<int>(type: "int", nullable: false),
                    PreviousStatus = table.Column<byte>(type: "tinyint", nullable: false),
                    NewStatus = table.Column<byte>(type: "tinyint", nullable: false),
                    ChangedAt = table.Column<DateTime>(type: "datetime2(3)", precision: 3, nullable: false),
                    ChangedBy = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_RequestStatusHistory", x => x.Id);
                    table.CheckConstraint("CK_RequestStatusHistory_NewStatus", "[NewStatus] BETWEEN 1 AND 4");
                    table.CheckConstraint("CK_RequestStatusHistory_PreviousStatus", "[PreviousStatus] BETWEEN 1 AND 4");
                    table.CheckConstraint("CK_RequestStatusHistory_StatusChanged", "[PreviousStatus] <> [NewStatus]");
                    table.ForeignKey(
                        name: "FK_RequestStatusHistory_Requests_RequestId",
                        column: x => x.RequestId,
                        principalTable: "Requests",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_RequestStatusHistory_RequestId_ChangedAt",
                table: "RequestStatusHistory",
                columns: new[] { "RequestId", "ChangedAt" },
                descending: new[] { false, true });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "RequestStatusHistory");

            migrationBuilder.DropTable(
                name: "Requests");
        }
    }
}
