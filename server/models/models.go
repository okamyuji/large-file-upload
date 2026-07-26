package models

import (
	"time"
)

// CreateSessionRequest セッション作成リクエスト
type CreateSessionRequest struct {
	FileName     string `json:"fileName" validate:"required,max=255"`
	TotalChunks  int    `json:"totalChunks" validate:"required,min=1,max=10000"`
	FileSize     int64  `json:"fileSize" validate:"required,min=1"`
	FileChecksum string `json:"fileChecksum" validate:"required,len=64,hexadecimal"`
	ChunkSize    int    `json:"chunkSize" validate:"required,min=1024,max=10485760"`
}

// SessionResponse セッション作成レスポンス
type SessionResponse struct {
	SessionID string `json:"sessionId"`
	Status    string `json:"status"`
	Message   string `json:"message"`
}

// ChunkUploadResponse チャンクアップロードレスポンス
type ChunkUploadResponse struct {
	ChunkIndex int    `json:"chunkIndex"`
	Status     string `json:"status"`
	Message    string `json:"message"`
}

// StatusResponse ステータス確認レスポンス
type StatusResponse struct {
	SessionID      string  `json:"sessionId"`
	Status         string  `json:"status"`
	TotalChunks    int     `json:"totalChunks"`
	UploadedChunks int     `json:"uploadedChunks"`
	MissingChunks  []int   `json:"missingChunks"`
	Progress       float64 `json:"progress"`
	// ExpiresAt この時刻を過ぎるとサーバ側でセッションが削除され、再開できなくなる。
	ExpiresAt time.Time `json:"expiresAt"`
	// FinalizeError 結合や整合性検証が失敗した理由。status が error のときに入る。
	// これを返さないと、クライアントは失敗を知っても原因を利用者に示せない。
	FinalizeError string `json:"finalizeError,omitempty"`
	// FinalizeFatal やり直しても結果が変わらない失敗かどうか。
	// これを返さないと、クライアントは一時的な I/O 失敗まで終端として扱ってしまう。
	FinalizeFatal bool `json:"finalizeFatal,omitempty"`
}

// CompleteResponse アップロード完了レスポンス
type CompleteResponse struct {
	SessionID         string `json:"sessionId"`
	Status            string `json:"status"`
	FinalFileChecksum string `json:"finalFileChecksum"`
	FilePath          string `json:"filePath"`
	Message           string `json:"message"`
}

// DeleteResponse セッション削除レスポンス
type DeleteResponse struct {
	SessionID string `json:"sessionId"`
	Status    string `json:"status"`
	Message   string `json:"message"`
}

// ErrorResponse エラーレスポンス
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
	Details string `json:"details,omitempty"`
}

// UploadSession アップロードセッション情報
type UploadSession struct {
	ID             string            `json:"id"`
	FileName       string            `json:"fileName"`
	TotalChunks    int               `json:"totalChunks"`
	FileSize       int64             `json:"fileSize"`
	FileChecksum   string            `json:"fileChecksum"`
	ChunkSize      int               `json:"chunkSize"`
	Status         SessionStatus     `json:"status"`
	UploadedChunks map[int]ChunkInfo `json:"uploadedChunks"`
	CreatedAt      time.Time         `json:"createdAt"`
	UpdatedAt      time.Time         `json:"updatedAt"`
	CompletedAt    *time.Time        `json:"completedAt,omitempty"`
	WorkingDir     string            `json:"workingDir"`
	// FinalFilePath 結合後の最終ファイルパス。結合完了後にのみ値が入る。
	FinalFilePath string `json:"finalFilePath,omitempty"`
	// FinalizeError 結合または整合性検証が失敗した理由。再試行と原因通知の両方で使う。
	FinalizeError string `json:"finalizeError,omitempty"`
	// FinalizeFatal 何度やり直しても結果が変わらない失敗かどうか。
	// 全体チェックサム不一致がこれにあたる。再結合を繰り返さないための終端フラグ。
	FinalizeFatal bool `json:"finalizeFatal,omitempty"`
}

// Clone セッションの深いコピーを返す。ロック外でファイル I/O を行うための
// スナップショット取得に使う。UploadedChunks を共有すると結合中の書き込みと競合する。
func (s *UploadSession) Clone() *UploadSession {
	copied := *s
	copied.UploadedChunks = make(map[int]ChunkInfo, len(s.UploadedChunks))
	for index, info := range s.UploadedChunks {
		copied.UploadedChunks[index] = info
	}
	if s.CompletedAt != nil {
		completedAt := *s.CompletedAt
		copied.CompletedAt = &completedAt
	}
	return &copied
}

// ChunkInfo チャンク情報
type ChunkInfo struct {
	Index     int       `json:"index"`
	Size      int64     `json:"size"`
	Checksum  string    `json:"checksum"`
	FilePath  string    `json:"filePath"`
	CreatedAt time.Time `json:"createdAt"`
}

// SessionStatus セッションステータス
type SessionStatus string

const (
	StatusCreated   SessionStatus = "created"
	StatusUploading SessionStatus = "uploading"
	StatusReady     SessionStatus = "ready"
	// StatusCombining 全チャンクが揃い、最終ファイルへの結合を実行している最中。
	// クライアントはこの状態を見て「送信は終わったが確定はまだ」と表示できる。
	StatusCombining SessionStatus = "combining"
	StatusCompleted SessionStatus = "completed"
	StatusError     SessionStatus = "error"
)

// GetMissingChunks 未アップロードのチャンクインデックスを取得
func (s *UploadSession) GetMissingChunks() []int {
	missing := make([]int, 0)
	for i := 0; i < s.TotalChunks; i++ {
		if _, exists := s.UploadedChunks[i]; !exists {
			missing = append(missing, i)
		}
	}
	return missing
}

// GetProgress アップロード進捗を取得（0.0-1.0）
func (s *UploadSession) GetProgress() float64 {
	if s.TotalChunks == 0 {
		return 0.0
	}
	return float64(len(s.UploadedChunks)) / float64(s.TotalChunks)
}

// IsComplete 全チャンクアップロード完了かチェック
func (s *UploadSession) IsComplete() bool {
	return len(s.UploadedChunks) == s.TotalChunks
}

// UpdateStatus ステータス更新
func (s *UploadSession) UpdateStatus() {
	s.UpdatedAt = time.Now()

	// 結合フェーズに入った後の状態は巻き戻さない。重複チャンクの再受信で
	// combining が ready に戻ると、進行中の結合が無いように見えてしまう。
	if s.Status == StatusCombining || s.Status == StatusCompleted {
		return
	}

	if len(s.UploadedChunks) == 0 {
		s.Status = StatusCreated
	} else if s.IsComplete() {
		if s.Status != StatusCompleted {
			s.Status = StatusReady
		}
	} else {
		s.Status = StatusUploading
	}
}
