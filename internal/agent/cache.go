package agent

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/barathanaslan/studio-cli/internal/sample"
)

// sampleTTL: concurrent /stats requests within this window share one sample.
const sampleTTL = 1 * time.Second

// sampleCache is the anti-leak heart of the agent: samples happen ON DEMAND
// only, one at a time (single-flight), and a result is reused for sampleTTL.
// No background tickers, no history — an idle agent does exactly nothing.
type sampleCache struct {
	mu        sync.Mutex
	sampledAt time.Time
	data      []byte // marshaled Stats
	err       error
	inflight  chan struct{} // non-nil while a sample is being taken
}

// get returns the cached snapshot if fresh, joins an in-flight sample if one
// is running, or takes a new sample itself. Errors are cached for the same
// TTL so a broken sampler cannot cause a request stampede.
func (c *sampleCache) get(ctx context.Context) ([]byte, error) {
	for {
		c.mu.Lock()
		if !c.sampledAt.IsZero() && time.Since(c.sampledAt) < sampleTTL {
			data, err := c.data, c.err
			c.mu.Unlock()
			return data, err
		}
		if c.inflight != nil {
			done := c.inflight
			c.mu.Unlock()
			select {
			case <-done:
				continue // re-read the now-fresh cache
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		done := make(chan struct{})
		c.inflight = done
		c.mu.Unlock()

		// Sample outside the lock. Use a detached timeout context: one
		// client disconnecting must not cancel the shared sample.
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		stats, err := sample.Collect(sctx)
		cancel()
		var data []byte
		if err == nil {
			data, err = json.Marshal(stats)
		}

		c.mu.Lock()
		c.data, c.err, c.sampledAt = data, err, time.Now()
		c.inflight = nil
		close(done)
		c.mu.Unlock()
		return data, err
	}
}
