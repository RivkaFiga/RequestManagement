using Microsoft.AspNetCore.Mvc;
using RequestManagement.Api.Http;
using RequestManagement.Core.Requests;

namespace RequestManagement.Api.Controllers;

[ApiController]
[Route("api/requests")]
public sealed class RequestsController(
    IRequestQueryService requests,
    IRequestStatusService statuses,
    ILogger<RequestsController> logger) : ControllerBase
{
    /// <summary>Searches, filters, sorts and pages requests.</summary>
    /// <remarks>
    /// Repeat <c>status</c> / <c>priority</c> for several values (<c>?status=New&amp;status=Waiting</c>).
    /// Filters combine with AND. <c>createdFrom</c> is inclusive and <c>createdTo</c> exclusive (UTC; send an offset or <c>Z</c>).
    /// </remarks>
    [HttpGet]
    [ProducesResponseType<PagedResult<RequestDto>>(StatusCodes.Status200OK)]
    [ProducesResponseType<ValidationProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<PagedResult<RequestDto>>> Search([FromQuery] RequestSearchQuery query, CancellationToken ct)
    {
        var result = await requests.SearchAsync(query, ct);
        logger.LogDebug("Search returned {Returned} of {Total} requests (page {Page}, size {PageSize}).",
            result.Items.Count, result.TotalCount, result.Page, result.PageSize);
        return result;
    }

    /// <summary>Counts of all requests by status and by priority, plus the total (ignores list filters).</summary>
    [HttpGet("summary")]
    [ProducesResponseType<RequestSummaryDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<RequestSummaryDto>> GetSummary(CancellationToken ct)
    {
        var summary = await requests.GetSummaryAsync(ct);
        logger.LogDebug("Summary computed for {Total} requests.", summary.Total);
        return summary;
    }

    /// <summary>Gets one request.</summary>
    [HttpGet("{id:int}")]
    [ProducesResponseType<RequestDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<RequestDto>> GetById(int id, CancellationToken ct)
    {
        var request = await requests.GetByIdAsync(id, ct);
        if (request is null)
        {
            return Problem(statusCode: StatusCodes.Status404NotFound, title: "Request not found.", detail: $"No request with id {id} exists.");
        }

        return request;
    }

    /// <summary>Changes the status of a request (optimistic concurrency, recorded in the history).</summary>
    /// <remarks>
    /// Send the <c>rowVersion</c> from the last response. 409 means someone else changed the request first
    /// (the body carries <c>currentStatus</c> and <c>currentRowVersion</c>); 422 means the transition is not allowed.
    /// The optional <c>X-User-Name</c> header (at most 100 characters, not authenticated) is stored as <c>changedBy</c>.
    /// </remarks>
    [HttpPatch("{id:int}/status")]
    [ProducesResponseType<RequestDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ValidationProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status422UnprocessableEntity)]
    public async Task<ActionResult<RequestDto>> UpdateStatus(int id, UpdateStatusRequest body, CancellationToken ct)
    {
        if (!HttpContext.TryGetChangedBy(out var changedBy, out var headerError))
        {
            ModelState.AddModelError(ChangedBy.HeaderName, headerError!);
            return ValidationProblem(ModelState);
        }

        var result = await statuses.UpdateStatusAsync(id, body.Status!.Value, body.RowVersionBytes, changedBy, ct);
        switch (result.Outcome)
        {
            case StatusUpdateOutcome.Updated:
                return result.Request!;

            case StatusUpdateOutcome.NotFound:
                return Problem(statusCode: StatusCodes.Status404NotFound, title: "Request not found.", detail: result.Error);

            case StatusUpdateOutcome.Conflict:
                var conflict = ProblemDetailsFactory.CreateProblemDetails(
                    HttpContext, StatusCodes.Status409Conflict, title: "Concurrency conflict.", detail: result.Error);
                conflict.Extensions["currentStatus"] = result.CurrentStatus;
                conflict.Extensions["currentRowVersion"] = result.CurrentRowVersion;
                return Conflict(conflict);

            default:
                return Problem(statusCode: StatusCodes.Status422UnprocessableEntity, title: "Status transition not allowed.", detail: result.Error);
        }
    }
}
