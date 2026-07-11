package utils

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"large-file-upload-server/models"
)

// GenerateSessionID ユニークなセッションIDを生成
func GenerateSessionID() string {
	timestamp := time.Now().Unix()
	randomBytes := make([]byte, 8)
	if _, err := rand.Read(randomBytes); err != nil {
		// crypto/rand.Read はエントロピー枯渇時のみ失敗するので、
		// タイムスタンプのみに縮退してでも ID を返す
		return fmt.Sprintf("session_%d_0000000000000000", timestamp)
	}
	return fmt.Sprintf("session_%d_%s", timestamp, hex.EncodeToString(randomBytes))
}

// CalculateFileChecksum ファイルのSHA256チェックサムを計算
func CalculateFileChecksum(filePath string) (string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("ファイルを開けません: %w", err)
	}
	defer func() { _ = file.Close() }()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return "", fmt.Errorf("ファイル読み込みエラー: %w", err)
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// CalculateChecksum データのSHA256チェックサムを計算
func CalculateChecksum(data []byte) string {
	hasher := sha256.New()
	_, _ = hasher.Write(data)
	return hex.EncodeToString(hasher.Sum(nil))
}

// ValidateChecksum チェックサム文字列の妥当性検証
func ValidateChecksum(checksum string) bool {
	if len(checksum) != 64 {
		return false
	}
	matched, _ := regexp.MatchString("^[a-f0-9]{64}$", checksum)
	return matched
}

// CreateWorkingDirectory セッション用の作業ディレクトリを作成
func CreateWorkingDirectory(sessionID string) (string, error) {
	baseDir := "uploads"
	workingDir := filepath.Join(baseDir, sessionID)

	err := os.MkdirAll(workingDir, 0755)
	if err != nil {
		return "", fmt.Errorf("作業ディレクトリ作成エラー: %w", err)
	}

	return workingDir, nil
}

// CleanupWorkingDirectory 作業ディレクトリとその中身を削除
func CleanupWorkingDirectory(workingDir string) error {
	if workingDir == "" || workingDir == "." || workingDir == "/" {
		return fmt.Errorf("安全でないディレクトリパス: %s", workingDir)
	}

	return os.RemoveAll(workingDir)
}

// WriteJSONResponse JSONレスポンスを書き込み
func WriteJSONResponse(w http.ResponseWriter, statusCode int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)

	if data != nil {
		if err := json.NewEncoder(w).Encode(data); err != nil {
			// JSONエンコードエラーの場合は500エラーを返す
			http.Error(w, "JSON encoding error", http.StatusInternalServerError)
		}
	}
}

// WriteErrorResponse エラーレスポンスを書き込み
func WriteErrorResponse(w http.ResponseWriter, statusCode int, errorCode, message string, details ...string) {
	errorResp := models.ErrorResponse{
		Error:   errorCode,
		Message: message,
	}

	if len(details) > 0 {
		errorResp.Details = details[0]
	}

	WriteJSONResponse(w, statusCode, errorResp)
}

// ParsePathParameter パスパラメータを解析
func ParsePathParameter(path, pattern string) map[string]string {
	params := make(map[string]string)

	// パターンを正規表現に変換
	regexPattern := strings.ReplaceAll(pattern, "{sessionId}", "([^/]+)")
	regexPattern = strings.ReplaceAll(regexPattern, "{chunkIndex}", "([0-9]+)")
	regexPattern = "^" + regexPattern + "$"

	re := regexp.MustCompile(regexPattern)
	matches := re.FindStringSubmatch(path)

	if len(matches) > 1 {
		// sessionIdの抽出
		if strings.Contains(pattern, "{sessionId}") {
			params["sessionId"] = matches[1]
		}
		// chunkIndexの抽出（2つ目のパラメータの場合）
		if strings.Contains(pattern, "{chunkIndex}") && len(matches) > 2 {
			params["chunkIndex"] = matches[2]
		} else if strings.Contains(pattern, "{chunkIndex}") && len(matches) > 1 && !strings.Contains(pattern, "{sessionId}") {
			params["chunkIndex"] = matches[1]
		}
	}

	return params
}

// ParseChunkIndex チャンクインデックスをintに変換
func ParseChunkIndex(chunkIndexStr string) (int, error) {
	chunkIndex, err := strconv.Atoi(chunkIndexStr)
	if err != nil {
		return 0, fmt.Errorf("無効なチャンクインデックス: %s", chunkIndexStr)
	}

	if chunkIndex < 0 {
		return 0, fmt.Errorf("チャンクインデックスは0以上である必要があります: %d", chunkIndex)
	}

	return chunkIndex, nil
}

// ValidateFileName ファイル名の妥当性検証
func ValidateFileName(fileName string) error {
	if fileName == "" {
		return fmt.Errorf("ファイル名が空です")
	}

	if len(fileName) > 255 {
		return fmt.Errorf("ファイル名が長すぎます（最大255文字）")
	}

	// 危険な文字をチェック
	dangerousChars := []string{"..", "/", "\\", ":", "*", "?", "\"", "<", ">", "|"}
	for _, char := range dangerousChars {
		if strings.Contains(fileName, char) {
			return fmt.Errorf("ファイル名に使用できない文字が含まれています: %s", char)
		}
	}

	return nil
}

// EnsureUploadsDirectory uploadsディレクトリが存在することを確認
func EnsureUploadsDirectory() error {
	return os.MkdirAll("uploads", 0755)
}

// GetFileSize ファイルサイズを取得
func GetFileSize(filePath string) (int64, error) {
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		return 0, err
	}
	return fileInfo.Size(), nil
}

// CombineChunks チャンクファイルを結合して最終ファイルを作成
func CombineChunks(session *models.UploadSession) (string, error) {
	finalFilePath := filepath.Join(session.WorkingDir, session.FileName)

	finalFile, err := os.Create(finalFilePath)
	if err != nil {
		return "", fmt.Errorf("最終ファイル作成エラー: %w", err)
	}
	defer func() { _ = finalFile.Close() }()

	// チャンクを順序通りに結合
	for i := 0; i < session.TotalChunks; i++ {
		chunkInfo, exists := session.UploadedChunks[i]
		if !exists {
			return "", fmt.Errorf("チャンク %d が見つかりません", i)
		}

		chunkFile, err := os.Open(chunkInfo.FilePath)
		if err != nil {
			return "", fmt.Errorf("チャンクファイル %d 読み込みエラー: %w", i, err)
		}

		_, err = io.Copy(finalFile, chunkFile)
		_ = chunkFile.Close()

		if err != nil {
			return "", fmt.Errorf("チャンク %d 結合エラー: %w", i, err)
		}
	}

	return finalFilePath, nil
}

// EnableCORS CORSヘッダーを設定
func EnableCORS(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Chunk-Checksum")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
	}
}

// ChunkLock チャンクレベルのロック管理
type ChunkLock struct {
	LockFile *os.File
	FilePath string
}

// AcquireChunkLock チャンクの排他ロックを取得
func AcquireChunkLock(sessionID string, chunkIndex int, timeout time.Duration) (*ChunkLock, error) {
	lockFileName := fmt.Sprintf("chunk_%d.lock", chunkIndex)
	lockFilePath := filepath.Join("uploads", sessionID, lockFileName)
	
	// ロックファイルの作成または開く
	lockFile, err := os.OpenFile(lockFilePath, os.O_CREATE|os.O_RDWR, 0666)
	if err != nil {
		return nil, fmt.Errorf("ロックファイル作成エラー: %w", err)
	}

	// タイムアウト付きでロック取得を試行
	done := make(chan error, 1)
	go func() {
		// LOCK_EX（排他ロック）を取得
		done <- syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX)
	}()

	select {
	case err := <-done:
		if err != nil {
			_ = lockFile.Close()
			return nil, fmt.Errorf("ロック取得エラー: %w", err)
		}
		return &ChunkLock{
			LockFile: lockFile,
			FilePath: lockFilePath,
		}, nil
	case <-time.After(timeout):
		_ = lockFile.Close()
		return nil, errors.New("ロック取得タイムアウト")
	}
}

// Release ロックを解放
func (cl *ChunkLock) Release() error {
	if cl.LockFile == nil {
		return nil
	}
	
	// ロック解放
	err := syscall.Flock(int(cl.LockFile.Fd()), syscall.LOCK_UN)
	if err != nil {
		_ = cl.LockFile.Close()
		return fmt.Errorf("ロック解放エラー: %w", err)
	}
	
	// ファイルクローズ
	closeErr := cl.LockFile.Close()
	
	// ロックファイル削除
	removeErr := os.Remove(cl.FilePath)
	
	if closeErr != nil {
		return fmt.Errorf("ロックファイルクローズエラー: %w", closeErr)
	}
	if removeErr != nil && !os.IsNotExist(removeErr) {
		return fmt.Errorf("ロックファイル削除エラー: %w", removeErr)
	}
	
	return nil
}

// AtomicChunkWrite 原子的なチャンク書き込み
func AtomicChunkWrite(filePath string, data []byte) error {
	// 一時ファイルパスを生成
	tempFilePath := filePath + ".tmp." + generateRandomString(8)
	
	// 一時ファイルに書き込み
	tempFile, err := os.Create(tempFilePath)
	if err != nil {
		return fmt.Errorf("一時ファイル作成エラー: %w", err)
	}
	
	// データ書き込み
	_, writeErr := tempFile.Write(data)
	closeErr := tempFile.Close()
	
	if writeErr != nil {
		_ = os.Remove(tempFilePath) // クリーンアップ
		return fmt.Errorf("一時ファイル書き込みエラー: %w", writeErr)
	}
	
	if closeErr != nil {
		_ = os.Remove(tempFilePath) // クリーンアップ
		return fmt.Errorf("一時ファイルクローズエラー: %w", closeErr)
	}
	
	// 一時ファイルを最終ファイルに原子的に移動
	if err := os.Rename(tempFilePath, filePath); err != nil {
		_ = os.Remove(tempFilePath) // クリーンアップ
		return fmt.Errorf("ファイル移動エラー: %w", err)
	}
	
	return nil
}

// generateRandomString ランダム文字列生成（内部用）
func generateRandomString(length int) string {
	bytes := make([]byte, length)
	_, _ = rand.Read(bytes)
	return hex.EncodeToString(bytes)[:length]
}

// CheckChunkExists チャンクファイルの存在確認
func CheckChunkExists(sessionID string, chunkIndex int) (bool, error) {
	chunkFileName := fmt.Sprintf("chunk_%d.dat", chunkIndex)
	chunkFilePath := filepath.Join("uploads", sessionID, chunkFileName)
	
	_, err := os.Stat(chunkFilePath)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
}
