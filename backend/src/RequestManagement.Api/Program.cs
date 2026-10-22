using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore;
using RequestManagement.Api.Http;
using RequestManagement.Core.Domain;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Persistence;
using RequestManagement.Infrastructure.Requests;

var builder = WebApplication.CreateBuilder(args);

// Enums travel as strings in both MVC and the OpenAPI/ProblemDetails serializers.
builder.Services
    .AddControllers()
    .AddJsonOptions(options => options.JsonSerializerOptions.Converters.Add(new JsonStringEnumConverter()));
builder.Services.ConfigureHttpJsonOptions(options => options.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));

// Errors are application/problem+json; unhandled exceptions never expose internals.
builder.Services.AddProblemDetails(options =>
    options.CustomizeProblemDetails = context =>
        context.ProblemDetails.Extensions["traceId"] = context.HttpContext.TraceIdentifier);
builder.Services.AddExceptionHandler<GlobalExceptionHandler>();

builder.Services.AddOpenApi();

// Lifetimes: plan §4.1.
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<StatusTransitionPolicy>();
builder.Services.AddDbContext<AppDbContext>((serviceProvider, options) =>
{
    // Resolved lazily so tests (and user-secrets / environment variables) can supply it after startup wiring.
    var connectionString = serviceProvider.GetRequiredService<IConfiguration>().GetConnectionString("RequestManagement")
        ?? throw new InvalidOperationException(
            "Connection string 'RequestManagement' is not configured. Set it with user-secrets or the " +
            "ConnectionStrings__RequestManagement environment variable (see README).");
    options.UseSqlServer(connectionString);
});
builder.Services
    .AddOptions<SummaryCacheOptions>()
    .Bind(builder.Configuration.GetSection(SummaryCacheOptions.SectionName))
    .Validate(options => options.ExpirationSeconds > 0, $"{SummaryCacheOptions.SectionName}:ExpirationSeconds must be greater than 0.")
    .ValidateOnStart();
builder.Services.AddSingleton<RequestSummaryCache>();
builder.Services.AddScoped<IRequestQueryService, RequestQueryService>();
builder.Services.AddScoped<IRequestStatusService, RequestStatusService>();

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
    app.UseSwaggerUI(options => options.SwaggerEndpoint("/openapi/v1.json", "RequestManagement API v1"));
}

app.MapControllers();

app.Run();

/// <summary>Entry point type, public so integration tests can host the API in-process.</summary>
public partial class Program;
