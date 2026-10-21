using RequestManagement.Core.Requests;

namespace RequestManagement.Api.Http;

public static class HttpContextExtensions
{
    /// <summary>
    /// Reads <c>ChangedBy</c> from the <c>X-User-Name</c> header (assumption A2); <c>"anonymous"</c> when absent.
    /// </summary>
    public static bool TryGetChangedBy(this HttpContext context, out string changedBy, out string? error) =>
        ChangedBy.TryResolve(context.Request.Headers[ChangedBy.HeaderName].ToString(), out changedBy, out error);
}
