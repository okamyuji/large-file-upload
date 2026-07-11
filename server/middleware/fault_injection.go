// Package middleware provides HTTP middlewares for the upload server.
package middleware

import (
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
)

// FaultInjectionConfig controls the fault-injection behavior.
type FaultInjectionConfig struct {
	// Rate is [0.0, 1.0]. 0 disables injection.
	Rate float64
	// StatusCode injected on hit. Default 503.
	StatusCode int
	// PathPrefix limits injection to matching URL paths. Empty means all.
	PathPrefix string
	// rand is the source; injected for tests.
	rand *rand.Rand
	mu   sync.Mutex
}

// NewFaultInjectionConfig reads the LARGE_FILE_UPLOAD_FAULT_RATE env var.
// If the env var is unset, empty, "0", or malformed, returns a disabled config.
func NewFaultInjectionConfig() *FaultInjectionConfig {
	raw := strings.TrimSpace(os.Getenv("LARGE_FILE_UPLOAD_FAULT_RATE"))
	if raw == "" {
		return &FaultInjectionConfig{Rate: 0}
	}
	rate, err := strconv.ParseFloat(raw, 64)
	if err != nil || rate < 0 || rate > 1 {
		return &FaultInjectionConfig{Rate: 0}
	}
	seed := int64(0)
	if s := os.Getenv("LARGE_FILE_UPLOAD_FAULT_SEED"); s != "" {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			seed = n
		}
	}
	return &FaultInjectionConfig{
		Rate:       rate,
		StatusCode: 503,
		PathPrefix: "/upload/session/",
		// #nosec G404 -- fault injection is a test/dev tool, not security-sensitive
		rand: rand.New(rand.NewSource(seed)),
	}
}

// shouldInject decides whether the request should be short-circuited.
func (c *FaultInjectionConfig) shouldInject(r *http.Request) bool {
	if c.Rate <= 0 {
		return false
	}
	if c.PathPrefix != "" && !strings.HasPrefix(r.URL.Path, c.PathPrefix) {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.rand == nil {
		// #nosec G404 -- fallback for lazy init in tests
		c.rand = rand.New(rand.NewSource(0))
	}
	return c.rand.Float64() < c.Rate
}

// Handler wraps the given handler with fault injection.
// When disabled (Rate == 0), it is a pass-through with zero overhead beyond the wrapper call.
func (c *FaultInjectionConfig) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c.shouldInject(r) {
			code := c.StatusCode
			if code == 0 {
				code = http.StatusServiceUnavailable
			}
			http.Error(w, "fault-injected", code)
			return
		}
		next.ServeHTTP(w, r)
	})
}
