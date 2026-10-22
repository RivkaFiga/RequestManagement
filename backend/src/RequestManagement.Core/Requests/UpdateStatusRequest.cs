using System.ComponentModel.DataAnnotations;
using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>
/// Body of <c>PATCH /api/requests/{id}/status</c> (plan §4.2, decision D6): the wanted status and the
/// <c>rowVersion</c> (base64) the client last saw. Rules live in <see cref="Validate"/> so every problem is
/// reported together (decision D5).
/// </summary>
public sealed class UpdateStatusRequest : IValidatableObject
{
    public RequestStatus? Status { get; set; }

    public string? RowVersion { get; set; }

    /// <summary>The decoded <see cref="RowVersion"/>. Meaningful once the request is valid.</summary>
    public byte[] RowVersionBytes =>
        TryDecodeRowVersion(RowVersion, out var version) ? version : [];

    public static bool TryDecodeRowVersion(string? value, out byte[] version)
    {
        version = [];
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        // A base64 string never decodes to more bytes than its length.
        var buffer = new byte[value.Length];
        if (!Convert.TryFromBase64String(value, buffer, out var written) || written == 0)
        {
            return false;
        }

        version = buffer[..written];
        return true;
    }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (Status is not { } status)
        {
            yield return Error("status", "Status is required.");
        }
        else if (!Enum.IsDefined(status))
        {
            yield return Error("status", "Status is not a defined value.");
        }

        if (string.IsNullOrWhiteSpace(RowVersion))
        {
            yield return Error("rowVersion", "RowVersion is required.");
        }
        else if (!TryDecodeRowVersion(RowVersion, out _))
        {
            yield return Error("rowVersion", "RowVersion must be the base64 value returned by the API.");
        }
    }

    private static ValidationResult Error(string member, string message) => new(message, [member]);
}
