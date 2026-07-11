package middleware

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

// TestMain enforces that fault-injection env vars leaked from the developer's
// shell or CI runner cannot poison sibling test packages.
func TestMain(m *testing.M) {
	_ = os.Unsetenv("LARGE_FILE_UPLOAD_FAULT_RATE")
	_ = os.Unsetenv("LARGE_FILE_UPLOAD_FAULT_SEED")
	os.Exit(m.Run())
}

// helper to build a passthrough handler
func passthrough() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
}

func TestNewFaultInjectionConfig_DisabledByDefault(t *testing.T) {
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_RATE", "")
	cfg := NewFaultInjectionConfig()
	if cfg.Rate != 0 {
		t.Fatalf("expected disabled config, got Rate=%v", cfg.Rate)
	}
}

func TestNewFaultInjectionConfig_MalformedIsDisabled(t *testing.T) {
	cases := []string{"abc", "-1", "2", "1.1"}
	for _, raw := range cases {
		t.Run(raw, func(t *testing.T) {
			t.Setenv("LARGE_FILE_UPLOAD_FAULT_RATE", raw)
			cfg := NewFaultInjectionConfig()
			if cfg.Rate != 0 {
				t.Fatalf("expected disabled config for %q, got Rate=%v", raw, cfg.Rate)
			}
		})
	}
}

func TestHandler_PassThroughWhenDisabled(t *testing.T) {
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_RATE", "")
	cfg := NewFaultInjectionConfig()
	h := cfg.Handler(passthrough())
	req := httptest.NewRequest("PUT", "/upload/session/foo/chunk/0", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 pass-through, got %d", rec.Code)
	}
}

func TestHandler_InjectsWhenRateOne(t *testing.T) {
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_RATE", "1.0")
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_SEED", "42")
	cfg := NewFaultInjectionConfig()
	h := cfg.Handler(passthrough())
	req := httptest.NewRequest("PUT", "/upload/session/foo/chunk/0", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 injected, got %d", rec.Code)
	}
}

func TestHandler_PathPrefixOnly(t *testing.T) {
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_RATE", "1.0")
	cfg := NewFaultInjectionConfig()
	h := cfg.Handler(passthrough())
	// path prefix mismatch — should pass through even at rate=1
	req := httptest.NewRequest("GET", "/health", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for non-matching path, got %d", rec.Code)
	}
}

func TestHandler_ApproximatesRate(t *testing.T) {
	// With rate=0.5 over many samples, injected count should be roughly half.
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_RATE", "0.5")
	t.Setenv("LARGE_FILE_UPLOAD_FAULT_SEED", "1")
	cfg := NewFaultInjectionConfig()
	h := cfg.Handler(passthrough())
	const n = 1000
	injected := 0
	for i := 0; i < n; i++ {
		req := httptest.NewRequest("PUT", "/upload/session/foo/chunk/0", nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code == http.StatusServiceUnavailable {
			injected++
		}
	}
	// Allow ±10% tolerance around 50%
	if injected < 400 || injected > 600 {
		t.Fatalf("expected ~500 injected of 1000, got %d", injected)
	}
}
