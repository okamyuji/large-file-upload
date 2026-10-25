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

// serveAndCaptureLog はリクエストを1つ処理し、その間に出たログの行を返す。
func serveAndCaptureLog(t *testing.T, method, target string) []string {
	t.Helper()
	t.Chdir(t.TempDir())
	service, err := services.NewUploadService()
	if err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	original := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(original) })

	NewUploadHandler(service).ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(method, target, nil))
	return strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
}

// リクエスト由来の改行がログ行を増やさず、偽のログ行を作れないことを確かめる。
func TestServeHTTPLogsRequestValuesOnOneLine(t *testing.T) {
	lines := serveAndCaptureLog(t, http.MethodGet, "/x%0D%0Aforged")

	if len(lines) != 2 { // DEBUG と NOT_FOUND の2行だけ
		t.Fatalf("ログが %d 行に分かれた: %q", len(lines), lines)
	}
	for _, line := range lines {
		if strings.ContainsAny(line, "\r") {
			t.Fatalf("CR がログに残っている: %q", line)
		}
	}
}

// 存在しないセッションの完了要求では、エラー文に含まれるセッション ID の改行がログ行を増やさない。
func TestCompleteUploadErrorLogStaysOnOneLinePerEntry(t *testing.T) {
	lines := serveAndCaptureLog(t, http.MethodPost, "/upload/session/abc%0A2026-01-01-FORGED/complete")

	for _, line := range lines {
		if strings.HasPrefix(line, "2026-01-01-FORGED") {
			t.Fatalf("セッション ID の改行で偽のログ行ができた: %q", lines)
		}
	}
	if !strings.Contains(strings.Join(lines, "\n"), "[COMPLETE] Error") {
		t.Fatalf("完了処理のエラーがログに出ていない: %q", lines)
	}
}
