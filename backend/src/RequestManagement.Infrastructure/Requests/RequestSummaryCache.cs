using Microsoft.Extensions.Options;
using RequestManagement.Core.Requests;

namespace RequestManagement.Infrastructure.Requests;

/// <summary>
/// In-memory cache of the one global summary (plan §4.5, decision D3). A singleton: the scoped services share it.
/// <para>
/// <b>Expiry.</b> A value is served for <see cref="SummaryCacheOptions.ExpirationSeconds"/>, counted from the moment
/// its computation <i>started</i> (the data can be that old, not older).
/// </para>
/// <para>
/// <b>Invalidation and the generation guard.</b> The status services call <see cref="Invalidate"/> after every
/// successful commit. Removing the entry is not enough on its own: a read that started before the commit may still be
/// running, and storing its result afterwards would put pre-update counts back for a whole expiry period. So every
/// invalidation also increments a generation counter, and a computed value is stored only if the generation is
/// unchanged since its computation started. Any stored value was therefore computed entirely after the last
/// invalidation, i.e. after the commit that caused it. The reader that lost the race still gets its value (it was
/// requested before the update) but it is never cached.
/// </para>
/// <para>
/// Concurrent misses each compute their own value (no single-flight): the cost is some duplicate SQL right after an
/// invalidation, the benefit is that no caller waits for, or inherits the failure or cancellation of, another.
/// </para>
/// </summary>
public sealed class RequestSummaryCache(IOptions<SummaryCacheOptions> options, TimeProvider clock)
{
    private readonly bool _enabled = options.Value.Enabled;
    private readonly TimeSpan _expiration = TimeSpan.FromSeconds(options.Value.ExpirationSeconds);
    private readonly object _gate = new();
    private long _generation;
    private Entry? _entry;

    /// <summary>
    /// Returns the cached summary, or runs <paramref name="compute"/> (a database read) and caches its result.
    /// An exception or cancellation in <paramref name="compute"/> propagates and nothing is cached.
    /// </summary>
    public async Task<RequestSummaryDto> GetOrCreateAsync(
        Func<CancellationToken, Task<RequestSummaryDto>> compute, CancellationToken ct)
    {
        if (!_enabled)
        {
            return await compute(ct);
        }

        long generation;
        long startedAt;
        lock (_gate)
        {
            if (_entry is { } cached && clock.GetElapsedTime(cached.StartedAt) < _expiration)
            {
                return cached.Value;
            }

            generation = _generation;
            startedAt = clock.GetTimestamp();
        }

        var value = await compute(ct);

        lock (_gate)
        {
            if (generation == _generation)
            {
                _entry = new Entry(value, startedAt);
            }
        }

        return value;
    }

    /// <summary>
    /// Drops the cached value and makes every computation that is already running unable to store its result.
    /// Call it after the change is committed, never before.
    /// </summary>
    public void Invalidate()
    {
        lock (_gate)
        {
            _generation++;
            _entry = null;
        }
    }

    private sealed record Entry(RequestSummaryDto Value, long StartedAt);
}
