package services

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"large-file-upload-server/models"
	"large-file-upload-server/utils"
)

// UploadService アップロードサービス
type UploadService struct {
	sessions    map[string]*models.UploadSession
	sessionsMux sync.RWMutex
}

// NewUploadService 新しいアップロードサービスを作成
func NewUploadService() *UploadService {
	return &UploadService{
		sessions: make(map[string]*models.UploadSession),
	}
}

// CreateSession 新しいアップロードセッションを作成
func (s *UploadService) CreateSession(req *models.CreateSessionRequest) (*models.UploadSession, error) {
	// バリデーション
	if err := s.validateCreateSessionRequest(req); err != nil {
		return nil, err
	}

	// セッションID生成
	sessionID := utils.GenerateSessionID()

	// 作業ディレクトリ作成
	workingDir, err := utils.CreateWorkingDirectory(sessionID)
	if err != nil {
		return nil, fmt.Errorf("作業ディレクトリ作成エラー: %w", err)
	}

	// セッション作成
	session := &models.UploadSession{
		ID:             sessionID,
		FileName:       req.FileName,
		TotalChunks:    req.TotalChunks,
		FileSize:       req.FileSize,
		FileChecksum:   req.FileChecksum,
		ChunkSize:      req.ChunkSize,
		Status:         models.StatusCreated,
		UploadedChunks: make(map[int]models.ChunkInfo),
		CreatedAt:      time.Now(),
		UpdatedAt:      time.Now(),
		WorkingDir:     workingDir,
	}

	// セッション保存
	s.sessionsMux.Lock()
	s.sessions[sessionID] = session
	s.sessionsMux.Unlock()

	return session, nil
}

// GetSession セッションを取得
func (s *UploadService) GetSession(sessionID string) (*models.UploadSession, bool) {
	s.sessionsMux.RLock()
	defer s.sessionsMux.RUnlock()

	session, exists := s.sessions[sessionID]
	return session, exists
}

// UploadChunk チャンクをアップロード
func (s *UploadService) UploadChunk(sessionID string, chunkIndex int, chunkData []byte, expectedChecksum string) error {
	// セッション取得
	session, exists := s.GetSession(sessionID)
	if !exists {
		return fmt.Errorf("セッションが見つかりません: %s", sessionID)
	}

	// チャンクインデックス検証
	if chunkIndex < 0 || chunkIndex >= session.TotalChunks {
		return fmt.Errorf("無効なチャンクインデックス: %d (範囲: 0-%d)", chunkIndex, session.TotalChunks-1)
	}

	// 既にアップロード済みかチェック
	s.sessionsMux.RLock()
	_, alreadyUploaded := session.UploadedChunks[chunkIndex]
	s.sessionsMux.RUnlock()

	if alreadyUploaded {
		return fmt.Errorf("チャンク %d は既にアップロード済みです", chunkIndex)
	}

	// チェックサム検証
	actualChecksum := utils.CalculateChecksum(chunkData)
	if actualChecksum != expectedChecksum {
		return fmt.Errorf("チェックサム不一致 - 期待値: %s, 実際の値: %s", expectedChecksum, actualChecksum)
	}

	// チャンクファイル保存
	chunkFileName := fmt.Sprintf("chunk_%d.dat", chunkIndex)
	chunkFilePath := filepath.Join(session.WorkingDir, chunkFileName)

	if err := s.saveChunkFile(chunkFilePath, chunkData); err != nil {
		return fmt.Errorf("チャンクファイル保存エラー: %w", err)
	}

	// チャンク情報更新
	chunkInfo := models.ChunkInfo{
		Index:     chunkIndex,
		Size:      int64(len(chunkData)),
		Checksum:  actualChecksum,
		FilePath:  chunkFilePath,
		CreatedAt: time.Now(),
	}

	s.sessionsMux.Lock()
	session.UploadedChunks[chunkIndex] = chunkInfo
	session.UpdateStatus()
	log.Printf("✅ [SERVICE] Chunk %d uploaded for session %s. Total: %d/%d", chunkIndex, sessionID, len(session.UploadedChunks), session.TotalChunks)
	s.sessionsMux.Unlock()

	return nil
}

// GetSessionStatus セッションステータスを取得
func (s *UploadService) GetSessionStatus(sessionID string) (*models.StatusResponse, error) {
	session, exists := s.GetSession(sessionID)
	if !exists {
		return nil, fmt.Errorf("セッションが見つかりません: %s", sessionID)
	}

	s.sessionsMux.RLock()
	defer s.sessionsMux.RUnlock()

	return &models.StatusResponse{
		SessionID:      session.ID,
		Status:         string(session.Status),
		TotalChunks:    session.TotalChunks,
		UploadedChunks: len(session.UploadedChunks),
		MissingChunks:  session.GetMissingChunks(),
		Progress:       session.GetProgress(),
	}, nil
}

// CompleteUpload アップロードを完了
func (s *UploadService) CompleteUpload(sessionID string) (*models.CompleteResponse, error) {
	session, exists := s.GetSession(sessionID)
	if !exists {
		return nil, fmt.Errorf("セッションが見つかりません: %s", sessionID)
	}

	s.sessionsMux.Lock()
	defer s.sessionsMux.Unlock()

	log.Printf("🔍 [SERVICE] CompleteUpload - SessionID: %s", sessionID)
	log.Printf("🔍 [SERVICE] Total chunks: %d, Uploaded chunks: %d", session.TotalChunks, len(session.UploadedChunks))
	log.Printf("🔍 [SERVICE] IsComplete: %t", session.IsComplete())
	log.Printf("🔍 [SERVICE] Status: %s", string(session.Status))

	// 全チャンクがアップロード済みかチェック
	if !session.IsComplete() {
		missingChunks := session.GetMissingChunks()
		log.Printf("❌ [SERVICE] Upload incomplete - missing chunks: %v", missingChunks)
		return nil, fmt.Errorf("アップロードが未完了です。未完了チャンク: %v", missingChunks)
	}

	// セッションが既に完了済みかチェック
	if session.Status == models.StatusCompleted {
		return &models.CompleteResponse{
			SessionID:         session.ID,
			Status:            string(session.Status),
			FinalFileChecksum: session.FileChecksum,
			FilePath:          filepath.Join(session.WorkingDir, session.FileName),
			Message:           "ファイルのアップロードは既に完了しています",
		}, nil
	}

	// チャンクを結合
	finalFilePath, err := utils.CombineChunks(session)
	if err != nil {
		session.Status = models.StatusError
		return nil, fmt.Errorf("ファイル結合エラー: %w", err)
	}

	// 最終ファイルのチェックサム検証
	finalChecksum, err := utils.CalculateFileChecksum(finalFilePath)
	if err != nil {
		session.Status = models.StatusError
		return nil, fmt.Errorf("最終ファイルチェックサム計算エラー: %w", err)
	}

	if finalChecksum != session.FileChecksum {
		session.Status = models.StatusError
		return nil, fmt.Errorf("ファイル整合性チェック失敗 - 期待値: %s, 実際の値: %s", session.FileChecksum, finalChecksum)
	}

	// セッション完了
	now := time.Now()
	session.Status = models.StatusCompleted
	session.UpdatedAt = now
	session.CompletedAt = &now

	// チャンクファイルをクリーンアップ
	s.cleanupChunkFiles(session)

	return &models.CompleteResponse{
		SessionID:         session.ID,
		Status:            string(session.Status),
		FinalFileChecksum: finalChecksum,
		FilePath:          finalFilePath,
		Message:           "ファイルのアップロードが完了しました",
	}, nil
}

// DeleteSession セッションを削除
func (s *UploadService) DeleteSession(sessionID string) error {
	session, exists := s.GetSession(sessionID)
	if !exists {
		return fmt.Errorf("セッションが見つかりません: %s", sessionID)
	}

	s.sessionsMux.Lock()
	defer s.sessionsMux.Unlock()

	// 作業ディレクトリを削除
	if err := utils.CleanupWorkingDirectory(session.WorkingDir); err != nil {
		return fmt.Errorf("作業ディレクトリクリーンアップエラー: %w", err)
	}

	// セッションを削除
	delete(s.sessions, sessionID)

	return nil
}

// validateCreateSessionRequest セッション作成リクエストのバリデーション
func (s *UploadService) validateCreateSessionRequest(req *models.CreateSessionRequest) error {
	if err := utils.ValidateFileName(req.FileName); err != nil {
		return fmt.Errorf("ファイル名エラー: %w", err)
	}

	if req.TotalChunks <= 0 || req.TotalChunks > 10000 {
		return fmt.Errorf("総チャンク数は1-10000の範囲で指定してください: %d", req.TotalChunks)
	}

	if req.FileSize <= 0 {
		return fmt.Errorf("ファイルサイズは1以上である必要があります: %d", req.FileSize)
	}

	if !utils.ValidateChecksum(req.FileChecksum) {
		return fmt.Errorf("無効なファイルチェックサム: %s", req.FileChecksum)
	}

	if req.ChunkSize < 1024 || req.ChunkSize > 10485760 {
		return fmt.Errorf("チャンクサイズは1024-10485760バイトの範囲で指定してください: %d", req.ChunkSize)
	}

	return nil
}

// saveChunkFile チャンクファイルを保存
func (s *UploadService) saveChunkFile(filePath string, data []byte) error {
	file, err := os.Create(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	_, err = file.Write(data)
	return err
}

// cleanupChunkFiles チャンクファイルを削除（最終ファイルは残す）
func (s *UploadService) cleanupChunkFiles(session *models.UploadSession) {
	for _, chunkInfo := range session.UploadedChunks {
		os.Remove(chunkInfo.FilePath)
	}
}

// GetAllSessions 全セッションを取得（デバッグ用）
func (s *UploadService) GetAllSessions() map[string]*models.UploadSession {
	s.sessionsMux.RLock()
	defer s.sessionsMux.RUnlock()

	// コピーを作成して返す
	result := make(map[string]*models.UploadSession)
	for k, v := range s.sessions {
		result[k] = v
	}
	return result
}

// CleanupExpiredSessions 期限切れセッションを削除
func (s *UploadService) CleanupExpiredSessions(maxAge time.Duration) int {
	s.sessionsMux.Lock()
	defer s.sessionsMux.Unlock()

	now := time.Now()
	deletedCount := 0

	for sessionID, session := range s.sessions {
		if now.Sub(session.UpdatedAt) > maxAge {
			utils.CleanupWorkingDirectory(session.WorkingDir)
			delete(s.sessions, sessionID)
			deletedCount++
		}
	}

	return deletedCount
}
