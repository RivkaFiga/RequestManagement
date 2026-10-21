using Microsoft.AspNetCore.Mvc;
using RequestManagement.Core.Requests;

namespace RequestManagement.Api.Controllers;

[ApiController]
[Route("api/requests")]
public sealed class RequestsController(IRequestQueryService requests, ILogger<RequestsController> logger) : ControllerBase
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
}
