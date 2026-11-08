package agent

import (
	"context"
	"sync"
	"time"
)

// cacheTTL: concurrent requests within this window share one result.
const cacheTTL = 1 * time.Second

// flight is the anti-leak heart of the agent: work happens ON DEMAND only,
// one at a time (single-flight), and a result is reused for ttl. No
// background tickers, no history — an idle agent does exactly nothing. It
// holds exactly one result (bounded state).
type flight[T any] struct {
	ttl     time.Duration
	timeout time.Duration
	fn      func(context.Context) (T, error)

	mu       sync.Mutex
	at       time.Time
	val      T
	err      error
	inflight chan struct{} // non-nil while fn is running
}

func newFlight[T any](ttl, timeout time.Duration, fn func(context.Context) (T, error)) *flight[T] {
	return &flight[T]{ttl: ttl, timeout: timeout, fn: fn}
}

// get returns the cached value if fresh, joins an in-flight call if one is
// running, or runs fn itself. Errors are cached for the same TTL so a broken
// sampler cannot cause a request stampede. Callers must not mutate a shared
// returned value — copy before trimming.
func (f *flight[T]) get(ctx context.Context) (T, error) {
	for {
		f.mu.Lock()
		if !f.at.IsZero() && time.Since(f.at) < f.ttl {
			v, err := f.val, f.err
			f.mu.Unlock()
			return v, err
		}
		if f.inflight != nil {
			done := f.inflight
			f.mu.Unlock()
			select {
			case <-done:
				continue // re-read the now-fresh cache
			case <-ctx.Done():
				var zero T
				return zero, ctx.Err()
			}
		}
		done := make(chan struct{})
		f.inflight = done
		f.mu.Unlock()

		// Run outside the lock with a detached timeout context: one client
		// disconnecting must not cancel the shared result.
		cctx, cancel := context.WithTimeout(context.Background(), f.timeout)
		v, err := f.fn(cctx)
		cancel()

		f.mu.Lock()
		f.val, f.err, f.at = v, err, time.Now()
		f.inflight = nil
		close(done)
		f.mu.Unlock()
		return v, err
	}
}
