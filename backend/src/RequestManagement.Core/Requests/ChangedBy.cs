namespace RequestManagement.Core.Requests;

/// <summary>
/// Resolves the <c>ChangedBy</c> value from the <c>X-User-Name</c> header (assumption A2).
/// The value is client-supplied and not authenticated.
/// </summary>
public static class ChangedBy
{
    public const string HeaderName = "X-User-Name";
    public const string Anonymous = "anonymous";
    public const int MaxLength = 100;

    /// <summary>
    /// Returns <c>true</c> with the trimmed name, or <c>"anonymous"</c> when the header is missing or blank.
    /// Returns <c>false</c> (and an error message) when the name is longer than <see cref="MaxLength"/>.
    /// </summary>
    public static bool TryResolve(string? headerValue, out string value, out string? error)
    {
        var trimmed = headerValue?.Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            value = Anonymous;
            error = null;
            return true;
        }

        if (trimmed.Length > MaxLength)
        {
            value = Anonymous;
            error = $"The {HeaderName} header must be at most {MaxLength} characters.";
            return false;
        }

        value = trimmed;
        error = null;
        return true;
    }
}
