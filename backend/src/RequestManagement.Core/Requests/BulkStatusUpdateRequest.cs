using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;
using RequestManagement.Core.Domain;

namespace RequestManagement.Core.Requests;

/// <summary>
/// Body of <c>POST /api/requests/bulk-status</c> (plan §4.2, R4.1, assumption A9): one target status and 1-100
/// items, each with the <c>rowVersion</c> (base64) the client last saw for that request. The envelope is validated
/// as a whole in <see cref="Validate"/> (decision D5), so a problem anywhere rejects the entire call with 400 and
/// nothing is changed. Only the per-item business outcomes (not found, conflict, disallowed transition) are
/// reported inside a 200 response.
/// </summary>
public sealed class BulkStatusUpdateRequest : IValidatableObject
{
    public const int MaxItems = 100;

    public RequestStatus? Status { get; set; }

    public List<BulkStatusUpdateItem?>? Items { get; set; }

    /// <summary>
    /// The decoded items. Meaningful once the request is valid; it never throws before that (MVC reads every public
    /// property while validating), it just skips items that have no id. Not part of the JSON contract, so it is
    /// absent from the request body and from the OpenAPI schema.
    /// </summary>
    [JsonIgnore]
    public IReadOnlyList<BulkStatusChange> Changes =>
        (Items ?? [])
            .Where(item => item?.Id is not null)
            .Select(item => new BulkStatusChange(item!.Id!.Value, item.RowVersionBytes))
            .ToList();

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

        if (Items is null || Items.Count == 0)
        {
            yield return Error("items", $"Items must contain between 1 and {MaxItems} items.");
            yield break;
        }

        if (Items.Count > MaxItems)
        {
            // Not inspected further: an oversized call is rejected without scanning it.
            yield return Error("items", $"Items must contain between 1 and {MaxItems} items; {Items.Count} were sent.");
            yield break;
        }

        for (var index = 0; index < Items.Count; index++)
        {
            if (Items[index] is not { } item)
            {
                yield return Error($"items[{index}]", "Item must not be null.");
                continue;
            }

            if (item.Id is null)
            {
                yield return Error($"items[{index}].id", "Id is required.");
            }

            if (string.IsNullOrWhiteSpace(item.RowVersion))
            {
                yield return Error($"items[{index}].rowVersion", "RowVersion is required.");
            }
            else if (!UpdateStatusRequest.TryDecodeRowVersion(item.RowVersion, out _))
            {
                yield return Error($"items[{index}].rowVersion", "RowVersion must be the base64 value returned by the API.");
            }
        }

        var duplicates = Items
            .Where(item => item?.Id is not null)
            .GroupBy(item => item!.Id!.Value)
            .Where(group => group.Count() > 1)
            .Select(group => group.Key)
            .Order()
            .ToList();
        if (duplicates.Count > 0)
        {
            var shown = string.Join(", ", duplicates.Take(10));
            var more = duplicates.Count > 10 ? $" and {duplicates.Count - 10} more" : string.Empty;
            yield return Error("items", $"Item ids must be distinct. Duplicate id(s): {shown}{more}.");
        }
    }

    private static ValidationResult Error(string member, string message) => new(message, [member]);
}

/// <summary>One entry of <see cref="BulkStatusUpdateRequest.Items"/>.</summary>
public sealed class BulkStatusUpdateItem
{
    public int? Id { get; set; }

    public string? RowVersion { get; set; }

    /// <summary>The decoded <see cref="RowVersion"/>. Meaningful once the request is valid. Not part of the JSON contract.</summary>
    [JsonIgnore]
    public byte[] RowVersionBytes =>
        UpdateStatusRequest.TryDecodeRowVersion(RowVersion, out var version) ? version : [];
}

/// <summary>A validated bulk item: the request to change and the version the client believes is current.</summary>
public sealed record BulkStatusChange(int Id, byte[] RowVersion);
