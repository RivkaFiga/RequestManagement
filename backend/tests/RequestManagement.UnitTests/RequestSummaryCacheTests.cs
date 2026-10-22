using Microsoft.Extensions.Options;
using RequestManagement.Core.Requests;
using RequestManagement.Infrastructure.Requests;

namespace RequestManagement.UnitTests;

/// <summary>UT-4 (T-208, R7.1-R7.3): hit, expiry, recompute after invalidation and the generation guard.</summary>
public class RequestSummaryCacheTests
{
    private static RequestSummaryCache CreateCache(ManualClock clock, bool enabled = true, int seconds = 60) =>
        new(Options.Create(new SummaryCacheOptions { Enabled = enabled, ExpirationSeconds = seconds }), clock);

    /// <summary>A summary whose Total identifies which "database state" it was computed from.</summary>
    private static RequestSummaryDto Summary(int total) => new(total, [], [], new DateTime(2026, 10, 22, 12, 0, 0, DateTimeKind.Utc));

    /// <summary>Counts how often the database would have been read, and returns the current <see cref="Truth"/>.</summary>
    private sealed class Source
    {
        private int _calls;

        public int Calls => Volatile.Read(ref _calls);

        public int Truth { get; set; } = 1;

        public Task<RequestSummaryDto> ComputeAsync(CancellationToken ct)
        {
            Interlocked.Increment(ref _calls);
            return Task.FromResult(Summary(Truth));
        }
    }

    [Fact]
    public async Task FirstCallComputes_AndTheNextCallsAreServedFromTheCache()
    {
        var source = new Source();
        var cache = CreateCache(new ManualClock());

        var first = await cache.GetOrCreateAsync(source.ComputeAsync, default);
        var second = await cache.GetOrCreateAsync(source.ComputeAsync, default);
        var third = await cache.GetOrCreateAsync(source.ComputeAsync, default);

        Assert.Equal(1, source.Calls);
        Assert.Same(first, second);
        Assert.Same(first, third);
    }

    [Fact]
    public async Task ACachedValue_IsNotRefreshedByDatabaseChangesUntilItExpires_OrIsInvalidated()
    {
        var source = new Source();
        var cache = CreateCache(new ManualClock());
        await cache.GetOrCreateAsync(source.ComputeAsync, default);

        source.Truth = 2; // the database changed behind the cache's back

        Assert.Equal(1, (await cache.GetOrCreateAsync(source.ComputeAsync, default)).Total);
    }

    [Fact]
    public async Task TheValueExpiresAfterTheConfiguredTime_AndIsThenRecomputed()
    {
        var clock = new ManualClock();
        var source = new Source();
        var cache = CreateCache(clock, seconds: 60);
        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        source.Truth = 2;

        clock.Advance(TimeSpan.FromSeconds(59.9));
        Assert.Equal(1, (await cache.GetOrCreateAsync(source.ComputeAsync, default)).Total);
        Assert.Equal(1, source.Calls);

        clock.Advance(TimeSpan.FromSeconds(0.1)); // exactly the expiration
        Assert.Equal(2, (await cache.GetOrCreateAsync(source.ComputeAsync, default)).Total);
        Assert.Equal(2, source.Calls);

        // The new value starts a new expiry period.
        clock.Advance(TimeSpan.FromSeconds(59));
        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        Assert.Equal(2, source.Calls);
    }

    [Fact]
    public async Task TheExpirationSetting_IsHonoured()
    {
        var clock = new ManualClock();
        var source = new Source();
        var cache = CreateCache(clock, seconds: 5);
        await cache.GetOrCreateAsync(source.ComputeAsync, default);

        clock.Advance(TimeSpan.FromSeconds(4));
        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        Assert.Equal(1, source.Calls);

        clock.Advance(TimeSpan.FromSeconds(1));
        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        Assert.Equal(2, source.Calls);
    }

    [Fact]
    public async Task ExpiryIsCountedFromTheStartOfTheComputation_NotFromItsEnd()
    {
        var clock = new ManualClock();
        var cache = CreateCache(clock, seconds: 60);
        var calls = 0;

        // A slow computation: the data it read is already 50 seconds old when it finishes.
        await cache.GetOrCreateAsync(_ =>
        {
            calls++;
            clock.Advance(TimeSpan.FromSeconds(50));
            return Task.FromResult(Summary(1));
        }, default);

        clock.Advance(TimeSpan.FromSeconds(9));
        await cache.GetOrCreateAsync(_ => Task.FromResult(Summary(2)), default);
        Assert.Equal(1, calls);

        clock.Advance(TimeSpan.FromSeconds(1)); // 60 s after the computation started
        Assert.Equal(2, (await cache.GetOrCreateAsync(_ => Task.FromResult(Summary(2)), default)).Total);
    }

    [Fact]
    public async Task Invalidate_ForcesARecompute_WithTheNewData()
    {
        var source = new Source();
        var cache = CreateCache(new ManualClock());
        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        source.Truth = 2;

        cache.Invalidate();

        Assert.Equal(2, (await cache.GetOrCreateAsync(source.ComputeAsync, default)).Total);
        Assert.Equal(2, source.Calls);
        await cache.GetOrCreateAsync(source.ComputeAsync, default); // and the fresh value is cached again
        Assert.Equal(2, source.Calls);
    }

    [Fact]
    public async Task GenerationGuard_AValueComputedAcrossAnInvalidation_IsReturned_ButNeverStored()
    {
        var cache = CreateCache(new ManualClock());
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        // A slow read begins and captures the pre-update counts (Total = 1)...
        var slowRead = cache.GetOrCreateAsync(async _ =>
        {
            var preUpdate = Summary(1);
            started.SetResult();
            await release.Task;
            return preUpdate;
        }, default);
        await started.Task;

        // ...an update commits and invalidates while that read is still running...
        cache.Invalidate();
        release.SetResult();

        // ...the slow read still gets its (requested-before-the-update) value...
        Assert.Equal(1, (await slowRead).Total);

        // ...but it must not have been stored: the next read computes the post-update counts.
        var source = new Source { Truth = 2 };
        Assert.Equal(2, (await cache.GetOrCreateAsync(source.ComputeAsync, default)).Total);
        Assert.Equal(1, source.Calls);
    }

    [Fact]
    public async Task GenerationGuard_AComputationStartedAfterTheInvalidation_IsStored()
    {
        var cache = CreateCache(new ManualClock());
        cache.Invalidate();
        var source = new Source();

        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        await cache.GetOrCreateAsync(source.ComputeAsync, default);

        Assert.Equal(1, source.Calls);
    }

    [Fact]
    public async Task GenerationGuard_ALateWriterCannotOverwriteANewerValue()
    {
        // Slow read A (pre-update) is still running when the update invalidates and fast read B stores post-update data.
        // When A finally finishes, the cache must keep B's value.
        var cache = CreateCache(new ManualClock());
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var slowRead = cache.GetOrCreateAsync(async _ =>
        {
            started.SetResult();
            await release.Task;
            return Summary(1);
        }, default);
        await started.Task;

        cache.Invalidate();
        await cache.GetOrCreateAsync(_ => Task.FromResult(Summary(2)), default); // B stores Total = 2
        release.SetResult();
        await slowRead;

        var source = new Source { Truth = 3 };
        Assert.Equal(2, (await cache.GetOrCreateAsync(source.ComputeAsync, default)).Total);
        Assert.Equal(0, source.Calls);
    }

    [Fact]
    public async Task AFailedOrCancelledComputation_IsNotCached_AndTheNextCallComputes()
    {
        var cache = CreateCache(new ManualClock());
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            cache.GetOrCreateAsync(_ => throw new InvalidOperationException("db down"), default));
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            cache.GetOrCreateAsync(ct => Task.FromCanceled<RequestSummaryDto>(ct), cancelled.Token));

        var source = new Source();
        await cache.GetOrCreateAsync(source.ComputeAsync, default);

        Assert.Equal(1, source.Calls);
    }

    [Fact]
    public async Task TheCancellationTokenIsPassedToTheComputation()
    {
        var cache = CreateCache(new ManualClock());
        using var cts = new CancellationTokenSource();
        CancellationToken seen = default;

        await cache.GetOrCreateAsync(ct =>
        {
            seen = ct;
            return Task.FromResult(Summary(1));
        }, cts.Token);

        Assert.Equal(cts.Token, seen);
    }

    [Fact]
    public async Task WhenDisabled_EveryCallComputes_AndNothingIsStored()
    {
        var source = new Source();
        var cache = CreateCache(new ManualClock(), enabled: false);

        await cache.GetOrCreateAsync(source.ComputeAsync, default);
        source.Truth = 2;
        cache.Invalidate(); // harmless
        var latest = await cache.GetOrCreateAsync(source.ComputeAsync, default);

        Assert.Equal(2, source.Calls);
        Assert.Equal(2, latest.Total);
    }

    [Fact]
    public async Task UnderParallelReadsAndWrites_NoStaleValueSurvivesTheLastInvalidation()
    {
        // Writers follow the protocol of the status services: change the data, then invalidate. Readers compute from
        // the data with a yield in the middle, which widens the window of the race. Once everything has stopped,
        // the cache must hand out the latest data, whatever the interleaving was.
        var cache = CreateCache(new ManualClock());
        var truth = 0;
        const int Writes = 400;
        using var stop = new CancellationTokenSource();

        async Task<RequestSummaryDto> ComputeAsync(CancellationToken ct)
        {
            var seen = Volatile.Read(ref truth);
            await Task.Yield();
            return Summary(seen);
        }

        var readers = Enumerable.Range(0, 6).Select(_ => Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                await cache.GetOrCreateAsync(ComputeAsync, default);
            }
        })).ToArray();

        var writer = Task.Run(async () =>
        {
            for (var i = 0; i < Writes; i++)
            {
                Interlocked.Increment(ref truth); // "commit"
                cache.Invalidate(); // then invalidate
                await Task.Yield();
            }
        });

        await writer;
        await stop.CancelAsync();
        await Task.WhenAll(readers);

        // All reads have finished: the cache is either empty or holds the final state.
        Assert.Equal(Writes, (await cache.GetOrCreateAsync(ComputeAsync, default)).Total);
    }

    /// <summary>A clock that only moves when told to.</summary>
    private sealed class ManualClock : TimeProvider
    {
        private long _ticks;

        public override long TimestampFrequency => TimeSpan.TicksPerSecond;

        public override long GetTimestamp() => Interlocked.Read(ref _ticks);

        public void Advance(TimeSpan by) => Interlocked.Add(ref _ticks, by.Ticks);
    }
}
