package handlers

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"large-file-upload-server/services"
)

// リクエスト由来の改行がログ行を増やさず、偽のログ行を作れないことを確かめる。
func TestServeHTTPLogsRequestValuesOnOneLine(t *testing.T) {
	t.Chdir(t.TempDir())
	service, err := services.NewUploadService()
	if err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	log.SetOutput(&buf)
	original := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(original) })

	req := httptest.NewRequest(http.MethodGet, "/x%0D%0Aforged", nil)
	rec := httptest.NewRecorder()
	NewUploadHandler(service).ServeHTTP(rec, req)

	lines := strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
	if len(lines) != 2 { // DEBUG と NOT_FOUND の2行だけ
		t.Fatalf("ログが %d 行に分かれた: %q", len(lines), buf.String())
	}
	for _, line := range lines {
		if strings.ContainsAny(line, "\r") {
			t.Fatalf("CR がログに残っている: %q", line)
		}
	}
}
