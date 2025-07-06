package handlers

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"

	"large-file-upload-server/models"
	"large-file-upload-server/services"
	"large-file-upload-server/utils"
)

// UploadHandler アップロードハンドラー
type UploadHandler struct {
	uploadService *services.UploadService
}

// NewUploadHandler 新しいアップロードハンドラーを作成
func NewUploadHandler(uploadService *services.UploadService) *UploadHandler {
	return &UploadHandler{
		uploadService: uploadService,
	}
}

// ServeHTTP HTTPリクエストを処理
func (h *UploadHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// CORS対応
	utils.EnableCORS(w, r)
	if r.Method == "OPTIONS" {
		return
	}

	// デバッグログ
	log.Printf("🔍 [DEBUG] %s %s", r.Method, r.URL.Path)

	// パスに基づいてルーティング
	path := r.URL.Path

	switch {
	case path == "/upload/session" && r.Method == "POST":
		log.Printf("✅ [ROUTE] createSession")
		h.createSession(w, r)
	case strings.HasPrefix(path, "/upload/session/") && strings.HasSuffix(path, "/status") && r.Method == "GET":
		log.Printf("✅ [ROUTE] getSessionStatus")
		h.getSessionStatus(w, r)
	case strings.HasPrefix(path, "/upload/session/") && strings.HasSuffix(path, "/complete") && r.Method == "POST":
		log.Printf("✅ [ROUTE] completeUpload")
		h.completeUpload(w, r)
	case strings.HasPrefix(path, "/upload/session/") && strings.Contains(path, "/chunk/") && r.Method == "PUT":
		log.Printf("✅ [ROUTE] uploadChunk")
		h.uploadChunk(w, r)
	case strings.HasPrefix(path, "/upload/session/") && r.Method == "DELETE":
		log.Printf("✅ [ROUTE] deleteSession")
		h.deleteSession(w, r)
	default:
		log.Printf("❌ [ROUTE] NOT_FOUND - path: %s, method: %s", path, r.Method)
		utils.WriteErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "エンドポイントが見つかりません")
	}
}

// createSession セッション作成
func (h *UploadHandler) createSession(w http.ResponseWriter, r *http.Request) {
	// Content-Type確認
	if r.Header.Get("Content-Type") != "application/json" {
		utils.WriteErrorResponse(w, http.StatusUnsupportedMediaType, "INVALID_CONTENT_TYPE", "Content-Typeはapplication/jsonである必要があります")
		return
	}

	// リクエストボディを読み込み
	var req models.CreateSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "INVALID_JSON", "JSONの解析に失敗しました", err.Error())
		return
	}

	// セッション作成
	session, err := h.uploadService.CreateSession(&req)
	if err != nil {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "SESSION_CREATION_FAILED", "セッション作成に失敗しました", err.Error())
		return
	}

	// レスポンス作成
	response := models.SessionResponse{
		SessionID: session.ID,
		Status:    string(session.Status),
		Message:   "アップロードセッションが作成されました",
	}

	utils.WriteJSONResponse(w, http.StatusCreated, response)
}

// uploadChunk チャンクアップロード
func (h *UploadHandler) uploadChunk(w http.ResponseWriter, r *http.Request) {
	// パスパラメータ解析
	params := utils.ParsePathParameter(r.URL.Path, "/upload/session/{sessionId}/chunk/{chunkIndex}")

	sessionID := params["sessionId"]
	if sessionID == "" {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "MISSING_SESSION_ID", "セッションIDが必要です")
		return
	}

	chunkIndexStr := params["chunkIndex"]
	if chunkIndexStr == "" {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "MISSING_CHUNK_INDEX", "チャンクインデックスが必要です")
		return
	}

	chunkIndex, err := utils.ParseChunkIndex(chunkIndexStr)
	if err != nil {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "INVALID_CHUNK_INDEX", "無効なチャンクインデックスです", err.Error())
		return
	}

	// チェックサムヘッダー確認
	expectedChecksum := r.Header.Get("X-Chunk-Checksum")
	if expectedChecksum == "" {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "MISSING_CHECKSUM", "X-Chunk-Checksumヘッダーが必要です")
		return
	}

	if !utils.ValidateChecksum(expectedChecksum) {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "INVALID_CHECKSUM", "無効なチェックサム形式です")
		return
	}

	// Content-Type確認
	if r.Header.Get("Content-Type") != "application/octet-stream" {
		utils.WriteErrorResponse(w, http.StatusUnsupportedMediaType, "INVALID_CONTENT_TYPE", "Content-Typeはapplication/octet-streamである必要があります")
		return
	}

	// チャンクデータ読み込み
	chunkData, err := io.ReadAll(r.Body)
	if err != nil {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "READ_ERROR", "チャンクデータの読み込みに失敗しました", err.Error())
		return
	}

	// チャンクサイズ制限チェック（10MB）
	maxChunkSize := 10 * 1024 * 1024
	if len(chunkData) > maxChunkSize {
		utils.WriteErrorResponse(w, http.StatusRequestEntityTooLarge, "CHUNK_TOO_LARGE", "チャンクサイズが大きすぎます")
		return
	}

	// チャンクアップロード
	err = h.uploadService.UploadChunk(sessionID, chunkIndex, chunkData, expectedChecksum)
	if err != nil {
		if strings.Contains(err.Error(), "セッションが見つかりません") {
			utils.WriteErrorResponse(w, http.StatusNotFound, "SESSION_NOT_FOUND", "セッションが見つかりません", err.Error())
		} else if strings.Contains(err.Error(), "既にアップロード済み") {
			utils.WriteErrorResponse(w, http.StatusConflict, "CHUNK_ALREADY_EXISTS", "チャンクが既に存在します", err.Error())
		} else if strings.Contains(err.Error(), "チェックサム不一致") {
			utils.WriteErrorResponse(w, http.StatusBadRequest, "CHECKSUM_MISMATCH", "チェックサムが一致しません", err.Error())
		} else {
			utils.WriteErrorResponse(w, http.StatusInternalServerError, "UPLOAD_FAILED", "チャンクアップロードに失敗しました", err.Error())
		}
		return
	}

	// レスポンス作成
	response := models.ChunkUploadResponse{
		ChunkIndex: chunkIndex,
		Status:     "uploaded",
		Message:    "チャンクが正常にアップロードされました",
	}

	utils.WriteJSONResponse(w, http.StatusOK, response)
}

// getSessionStatus セッションステータス取得
func (h *UploadHandler) getSessionStatus(w http.ResponseWriter, r *http.Request) {
	// パスパラメータ解析
	params := utils.ParsePathParameter(r.URL.Path, "/upload/session/{sessionId}/status")

	sessionID := params["sessionId"]
	if sessionID == "" {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "MISSING_SESSION_ID", "セッションIDが必要です")
		return
	}

	// セッションステータス取得
	status, err := h.uploadService.GetSessionStatus(sessionID)
	if err != nil {
		if strings.Contains(err.Error(), "セッションが見つかりません") {
			utils.WriteErrorResponse(w, http.StatusNotFound, "SESSION_NOT_FOUND", "セッションが見つかりません", err.Error())
		} else {
			utils.WriteErrorResponse(w, http.StatusInternalServerError, "STATUS_FETCH_FAILED", "ステータス取得に失敗しました", err.Error())
		}
		return
	}

	utils.WriteJSONResponse(w, http.StatusOK, status)
}

// completeUpload アップロード完了
func (h *UploadHandler) completeUpload(w http.ResponseWriter, r *http.Request) {
	// パスパラメータ解析
	params := utils.ParsePathParameter(r.URL.Path, "/upload/session/{sessionId}/complete")

	sessionID := params["sessionId"]
	if sessionID == "" {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "MISSING_SESSION_ID", "セッションIDが必要です")
		return
	}

	log.Printf("🏁 [COMPLETE] Starting completion for sessionId: %s", sessionID)

	// アップロード完了処理
	result, err := h.uploadService.CompleteUpload(sessionID)
	if err != nil {
		log.Printf("❌ [COMPLETE] Error: %v", err)
		if strings.Contains(err.Error(), "セッションが見つかりません") {
			utils.WriteErrorResponse(w, http.StatusNotFound, "SESSION_NOT_FOUND", "セッションが見つかりません", err.Error())
		} else if strings.Contains(err.Error(), "未完了") {
			utils.WriteErrorResponse(w, http.StatusBadRequest, "UPLOAD_INCOMPLETE", "アップロードが未完了です", err.Error())
		} else if strings.Contains(err.Error(), "整合性チェック失敗") {
			utils.WriteErrorResponse(w, http.StatusUnprocessableEntity, "INTEGRITY_CHECK_FAILED", "ファイル整合性チェックに失敗しました", err.Error())
		} else {
			utils.WriteErrorResponse(w, http.StatusInternalServerError, "COMPLETION_FAILED", "アップロード完了処理に失敗しました", err.Error())
		}
		return
	}

	log.Printf("✅ [COMPLETE] Success: %s", result.FilePath)
	utils.WriteJSONResponse(w, http.StatusOK, result)
}

// deleteSession セッション削除
func (h *UploadHandler) deleteSession(w http.ResponseWriter, r *http.Request) {
	// パスパラメータ解析
	params := utils.ParsePathParameter(r.URL.Path, "/upload/session/{sessionId}")

	sessionID := params["sessionId"]
	if sessionID == "" {
		utils.WriteErrorResponse(w, http.StatusBadRequest, "MISSING_SESSION_ID", "セッションIDが必要です")
		return
	}

	// セッション削除
	err := h.uploadService.DeleteSession(sessionID)
	if err != nil {
		if strings.Contains(err.Error(), "セッションが見つかりません") {
			utils.WriteErrorResponse(w, http.StatusNotFound, "SESSION_NOT_FOUND", "セッションが見つかりません", err.Error())
		} else {
			utils.WriteErrorResponse(w, http.StatusInternalServerError, "DELETION_FAILED", "セッション削除に失敗しました", err.Error())
		}
		return
	}

	// レスポンス作成
	response := models.DeleteResponse{
		SessionID: sessionID,
		Status:    "deleted",
		Message:   "セッションが削除されました",
	}

	utils.WriteJSONResponse(w, http.StatusOK, response)
}
