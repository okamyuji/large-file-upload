package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"large-file-upload-server/handlers"
	"large-file-upload-server/models"
	"large-file-upload-server/services"
	"large-file-upload-server/utils"
)

func TestUploadWorkflow(t *testing.T) {
	// テスト用のサービスとハンドラーを作成
	uploadService := services.NewUploadService()
	handler := handlers.NewUploadHandler(uploadService)

	// テストデータ準備
	testData := "Hello, World! This is test data for chunked upload."
	testDataBytes := []byte(testData)
	fileChecksum := utils.CalculateChecksum(testDataBytes)

	chunkSize := 10
	chunks := make([][]byte, 0)

	// データをチャンクに分割
	for i := 0; i < len(testDataBytes); i += chunkSize {
		end := i + chunkSize
		if end > len(testDataBytes) {
			end = len(testDataBytes)
		}
		chunks = append(chunks, testDataBytes[i:end])
	}

	t.Logf("テストデータ: %s", testData)
	t.Logf("ファイルサイズ: %d bytes", len(testDataBytes))
	t.Logf("チャンク数: %d", len(chunks))
	t.Logf("ファイルチェックサム: %s", fileChecksum)

	// 1. セッション作成テスト
	t.Run("セッション作成", func(t *testing.T) {
		sessionReq := models.CreateSessionRequest{
			FileName:     "test.txt",
			TotalChunks:  len(chunks),
			FileSize:     int64(len(testDataBytes)),
			FileChecksum: fileChecksum,
			ChunkSize:    chunkSize,
		}

		reqBody, _ := json.Marshal(sessionReq)
		req := httptest.NewRequest("POST", "/upload/session", bytes.NewReader(reqBody))
		req.Header.Set("Content-Type", "application/json")

		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusCreated {
			t.Fatalf("期待されるステータス: %d, 実際: %d, レスポンス: %s", http.StatusCreated, w.Code, w.Body.String())
		}

		var resp models.SessionResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("レスポンス解析エラー: %v", err)
		}

		if resp.SessionID == "" {
			t.Fatal("セッションIDが空です")
		}

		if resp.Status != "created" {
			t.Fatalf("期待されるステータス: created, 実際: %s", resp.Status)
		}

		t.Logf("セッションID: %s", resp.SessionID)

		// グローバル変数にセッションIDを保存（他のテストで使用）
		sessionID = resp.SessionID
	})

	// 2. チャンクアップロードテスト
	t.Run("チャンクアップロード", func(t *testing.T) {
		if sessionID == "" {
			t.Fatal("セッションIDが設定されていません")
		}

		for i, chunk := range chunks {
			chunkChecksum := utils.CalculateChecksum(chunk)

			req := httptest.NewRequest("PUT", fmt.Sprintf("/upload/session/%s/chunk/%d", sessionID, i), bytes.NewReader(chunk))
			req.Header.Set("Content-Type", "application/octet-stream")
			req.Header.Set("X-Chunk-Checksum", chunkChecksum)

			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)

			if w.Code != http.StatusOK {
				t.Fatalf("チャンク %d アップロード失敗: ステータス %d, レスポンス: %s", i, w.Code, w.Body.String())
			}

			var resp models.ChunkUploadResponse
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("チャンク %d レスポンス解析エラー: %v", i, err)
			}

			if resp.ChunkIndex != i {
				t.Fatalf("チャンク %d: 期待されるインデックス %d, 実際: %d", i, i, resp.ChunkIndex)
			}

			t.Logf("チャンク %d アップロード完了 (サイズ: %d bytes)", i, len(chunk))
		}
	})

	// 3. ステータス確認テスト
	t.Run("ステータス確認", func(t *testing.T) {
		if sessionID == "" {
			t.Fatal("セッションIDが設定されていません")
		}

		req := httptest.NewRequest("GET", fmt.Sprintf("/upload/session/%s/status", sessionID), nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("ステータス確認失敗: ステータス %d, レスポンス: %s", w.Code, w.Body.String())
		}

		var resp models.StatusResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("ステータスレスポンス解析エラー: %v", err)
		}

		if resp.TotalChunks != len(chunks) {
			t.Fatalf("期待される総チャンク数: %d, 実際: %d", len(chunks), resp.TotalChunks)
		}

		if resp.UploadedChunks != len(chunks) {
			t.Fatalf("期待されるアップロード済みチャンク数: %d, 実際: %d", len(chunks), resp.UploadedChunks)
		}

		if len(resp.MissingChunks) != 0 {
			t.Fatalf("未完了チャンクが存在します: %v", resp.MissingChunks)
		}

		if resp.Progress != 1.0 {
			t.Fatalf("期待される進捗: 1.0, 実際: %f", resp.Progress)
		}

		t.Logf("アップロード進捗: %.1f%% (%d/%d チャンク)", resp.Progress*100, resp.UploadedChunks, resp.TotalChunks)
	})

	// 4. アップロード完了テスト
	t.Run("アップロード完了", func(t *testing.T) {
		if sessionID == "" {
			t.Fatal("セッションIDが設定されていません")
		}

		req := httptest.NewRequest("POST", fmt.Sprintf("/upload/session/%s/complete", sessionID), nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("アップロード完了失敗: ステータス %d, レスポンス: %s", w.Code, w.Body.String())
		}

		var resp models.CompleteResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("完了レスポンス解析エラー: %v", err)
		}

		if resp.Status != "completed" {
			t.Fatalf("期待されるステータス: completed, 実際: %s", resp.Status)
		}

		if resp.FinalFileChecksum != fileChecksum {
			t.Fatalf("チェックサム不一致: 期待値 %s, 実際: %s", fileChecksum, resp.FinalFileChecksum)
		}

		t.Logf("アップロード完了: %s", resp.FilePath)
		t.Logf("最終チェックサム: %s", resp.FinalFileChecksum)
	})

	// 5. セッション削除テスト
	t.Run("セッション削除", func(t *testing.T) {
		if sessionID == "" {
			t.Fatal("セッションIDが設定されていません")
		}

		req := httptest.NewRequest("DELETE", fmt.Sprintf("/upload/session/%s", sessionID), nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("セッション削除失敗: ステータス %d, レスポンス: %s", w.Code, w.Body.String())
		}

		var resp models.DeleteResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("削除レスポンス解析エラー: %v", err)
		}

		if resp.Status != "deleted" {
			t.Fatalf("期待されるステータス: deleted, 実際: %s", resp.Status)
		}

		t.Logf("セッション削除完了: %s", resp.SessionID)
	})
}

func TestErrorCases(t *testing.T) {
	uploadService := services.NewUploadService()
	handler := handlers.NewUploadHandler(uploadService)

	// 無効なセッション作成リクエストテスト
	t.Run("無効なセッション作成", func(t *testing.T) {
		invalidReq := models.CreateSessionRequest{
			FileName:     "",        // 無効なファイル名
			TotalChunks:  0,         // 無効なチャンク数
			FileSize:     0,         // 無効なファイルサイズ
			FileChecksum: "invalid", // 無効なチェックサム
			ChunkSize:    0,         // 無効なチャンクサイズ
		}

		reqBody, _ := json.Marshal(invalidReq)
		req := httptest.NewRequest("POST", "/upload/session", bytes.NewReader(reqBody))
		req.Header.Set("Content-Type", "application/json")

		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusBadRequest {
			t.Fatalf("期待されるステータス: %d, 実際: %d", http.StatusBadRequest, w.Code)
		}
	})

	// 存在しないセッションへのチャンクアップロードテスト
	t.Run("存在しないセッションへのチャンクアップロード", func(t *testing.T) {
		testData := []byte("test")
		checksum := utils.CalculateChecksum(testData)

		req := httptest.NewRequest("PUT", "/upload/session/nonexistent/chunk/0", bytes.NewReader(testData))
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("X-Chunk-Checksum", checksum)

		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusNotFound {
			t.Fatalf("期待されるステータス: %d, 実際: %d", http.StatusNotFound, w.Code)
		}
	})

	// チェックサム不一致テスト
	t.Run("チェックサム不一致", func(t *testing.T) {
		// まず有効なセッションを作成
		sessionReq := models.CreateSessionRequest{
			FileName:     "test.txt",
			TotalChunks:  1,
			FileSize:     4,
			FileChecksum: utils.CalculateChecksum([]byte("test")),
			ChunkSize:    4,
		}

		reqBody, _ := json.Marshal(sessionReq)
		req := httptest.NewRequest("POST", "/upload/session", bytes.NewReader(reqBody))
		req.Header.Set("Content-Type", "application/json")

		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		var resp models.SessionResponse
		json.Unmarshal(w.Body.Bytes(), &resp)
		sessionID := resp.SessionID

		// 間違ったチェックサムでチャンクアップロード
		testData := []byte("test")
		wrongChecksum := utils.CalculateChecksum([]byte("wrong"))

		req = httptest.NewRequest("PUT", fmt.Sprintf("/upload/session/%s/chunk/0", sessionID), bytes.NewReader(testData))
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("X-Chunk-Checksum", wrongChecksum)

		w = httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusBadRequest {
			t.Fatalf("期待されるステータス: %d, 実際: %d", http.StatusBadRequest, w.Code)
		}
	})
}

func TestHealthEndpoint(t *testing.T) {
	uploadService := services.NewUploadService()
	handler := handlers.NewUploadHandler(uploadService)

	// ヘルスチェックエンドポイントのテスト用ハンドラー
	mux := http.NewServeMux()
	mux.Handle("/upload/", handler)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		utils.EnableCORS(w, r)
		if r.Method == "OPTIONS" {
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"healthy"}`))
	})

	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("期待されるステータス: %d, 実際: %d", http.StatusOK, w.Code)
	}

	body := w.Body.String()
	if !bytes.Contains([]byte(body), []byte("healthy")) {
		t.Fatalf("ヘルスチェックレスポンスが期待される内容を含んでいません: %s", body)
	}
}

// テスト間で共有するセッションID
var sessionID string
