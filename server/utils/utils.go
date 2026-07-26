package utils

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
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

// WriteErrorResponseWithRetryAfter Retry-After ヘッダを付与したエラーレスポンスを書き込み
// retryAfterSeconds は 429/503 で使用。値が 0 の場合はヘッダを設定しない。
func WriteErrorResponseWithRetryAfter(w http.ResponseWriter, statusCode int, retryAfterSeconds int, errorCode, message string, details ...string) {
	if retryAfterSeconds > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(retryAfterSeconds))
	}
	WriteErrorResponse(w, statusCode, errorCode, message, details...)
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

// CombineChunks チャンクファイルを結合して最終ファイルを作成する。
//
// 一時ファイルへ書いて fsync してから rename で確定させる。この順序が要るのは、
// 呼び出し側が結合完了を completed として記録し、そのあとチャンクの実体を削除するためである。
// 最終ファイルの中身がディスクに届く前に completed だけが永続化されると、電源断のあとに
// 「完了と記録されているが中身が欠けていて、作り直す材料も無い」という復旧不能な状態が残る。
func CombineChunks(session *models.UploadSession) (string, error) {
	finalFilePath := filepath.Join(session.WorkingDir, session.FileName)
	tempFilePath := finalFilePath + ".combining." + generateRandomString(8)

	finalFile, err := os.Create(tempFilePath)
	if err != nil {
		return "", fmt.Errorf("最終ファイル作成エラー: %w", err)
	}

	// チャンクを順序通りに結合
	combineErr := func() error {
		for i := 0; i < session.TotalChunks; i++ {
			chunkInfo, exists := session.UploadedChunks[i]
			if !exists {
				return fmt.Errorf("チャンク %d が見つかりません", i)
			}

			chunkFile, openErr := os.Open(chunkInfo.FilePath)
			if openErr != nil {
				return fmt.Errorf("チャンクファイル %d 読み込みエラー: %w", i, openErr)
			}

			_, copyErr := io.Copy(finalFile, chunkFile)
			_ = chunkFile.Close()

			if copyErr != nil {
				return fmt.Errorf("チャンク %d 結合エラー: %w", i, copyErr)
			}
		}
		// 中身をディスクへ届けてから rename する
		if syncErr := finalFile.Sync(); syncErr != nil {
			return fmt.Errorf("最終ファイル同期エラー: %w", syncErr)
		}
		return nil
	}()

	if closeErr := finalFile.Close(); closeErr != nil && combineErr == nil {
		combineErr = fmt.Errorf("最終ファイルクローズエラー: %w", closeErr)
	}

	if combineErr != nil {
		_ = os.Remove(tempFilePath)
		return "", combineErr
	}

	if err := os.Rename(tempFilePath, finalFilePath); err != nil {
		_ = os.Remove(tempFilePath)
		return "", fmt.Errorf("最終ファイル確定エラー: %w", err)
	}

	// rename 自体を耐久化するため親ディレクトリも同期する
	if dir, dirErr := os.Open(filepath.Dir(finalFilePath)); dirErr == nil {
		_ = dir.Sync()
		_ = dir.Close()
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

// uploadsRoot チャンク・ロックファイルを保存するルートディレクトリ
const uploadsRoot = "uploads"

// sessionIDPattern セッションIDとして許可する文字集合。
// GenerateSessionID が生成する "session_<unix>_<hex>" を包含しつつ、
// パス区切り文字や ".." を構成できない文字のみに制限する。
var sessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// SafeSessionFilePath uploads/<sessionID>/<fileName> のパスを検証付きで組み立てる。
// sessionID はURL由来の入力なので、形式検証に加えて解決後のパスが
// uploadsルート配下に収まることを確認する (path injection対策)。
func SafeSessionFilePath(sessionID, fileName string) (string, error) {
	if !sessionIDPattern.MatchString(sessionID) {
		return "", fmt.Errorf("不正なセッションID形式: %q", sessionID)
	}
	cleaned := filepath.Clean(filepath.Join(uploadsRoot, sessionID, fileName))
	if !strings.HasPrefix(cleaned, uploadsRoot+string(os.PathSeparator)) {
		return "", fmt.Errorf("パスがアップロードディレクトリ外を指しています: %q", cleaned)
	}
	return cleaned, nil
}

// ChunkLock チャンクレベルのロック管理
type ChunkLock struct {
	LockFile *os.File
	FilePath string
}

// AcquireChunkLock チャンクの排他ロックを取得
func AcquireChunkLock(sessionID string, chunkIndex int, timeout time.Duration) (*ChunkLock, error) {
	lockFileName := fmt.Sprintf("chunk_%d.lock", chunkIndex)
	lockFilePath, err := SafeSessionFilePath(sessionID, lockFileName)
	if err != nil {
		return nil, fmt.Errorf("ロックファイルパス検証エラー: %w", err)
	}

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

// AtomicWriteFile 一時ファイルへ書いて fsync してから rename で確定させる。
// fsync を省くと、rename が先に永続化されて中身が空のファイルだけが残る事故が起きる。
// 受け取り済みとして記録する前に、実体がディスクに載っていることを保証する。
func AtomicWriteFile(filePath string, data []byte) error {
	// 一時ファイルパスを生成
	tempFilePath := filePath + ".tmp." + generateRandomString(8)

	// 一時ファイルに書き込み
	tempFile, err := os.Create(tempFilePath)
	if err != nil {
		return fmt.Errorf("一時ファイル作成エラー: %w", err)
	}

	// データ書き込み → fsync → close の順で耐久化する
	_, writeErr := tempFile.Write(data)
	var syncErr error
	if writeErr == nil {
		syncErr = tempFile.Sync()
	}
	closeErr := tempFile.Close()

	if writeErr != nil {
		_ = os.Remove(tempFilePath) // クリーンアップ
		return fmt.Errorf("一時ファイル書き込みエラー: %w", writeErr)
	}

	if syncErr != nil {
		_ = os.Remove(tempFilePath) // クリーンアップ
		return fmt.Errorf("一時ファイル同期エラー: %w", syncErr)
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

	// rename 自体を耐久化するため親ディレクトリも同期する
	if dir, dirErr := os.Open(filepath.Dir(filePath)); dirErr == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	return nil
}

// AtomicChunkWrite 原子的なチャンク書き込み
func AtomicChunkWrite(filePath string, data []byte) error {
	return AtomicWriteFile(filePath, data)
}

// CleanupStaleTempFiles セッションの作業ディレクトリに残った書きかけの一時ファイルを削除する。
//
// 結合中や原子的書き込みの最中にプロセスが落ちると、`.combining.*` や `.tmp.*` が残る。
// 結合の一時ファイルは最終ファイルと同じ大きさになり得るので、再起動のたびに積み上がると
// 作業領域を使い切り、既存セッションの結合も新規チャンクの受信も失敗するようになる。
func CleanupStaleTempFiles(workingDir string) {
	entries, err := os.ReadDir(workingDir)
	if err != nil {
		return
	}

	for _, entry := range entries {
		name := entry.Name()
		if !strings.Contains(name, ".combining.") && !strings.Contains(name, ".tmp.") {
			continue
		}
		path := filepath.Join(workingDir, name)
		if removeErr := os.Remove(path); removeErr == nil {
			log.Printf("🧹 [CLEANUP] 書きかけの一時ファイルを削除: %s", path)
		}
	}
}

// sessionManifestName セッション状態を保存するマニフェストのファイル名
const sessionManifestName = "session.json"

// SaveSessionManifest セッション状態を作業ディレクトリへ原子的に書き出す。
// サーバをSoTとして扱う以上、受信済みチャンクの記録はプロセスの寿命を越えて残る必要がある。
func SaveSessionManifest(session *models.UploadSession) error {
	manifestPath, err := SafeSessionFilePath(session.ID, sessionManifestName)
	if err != nil {
		return fmt.Errorf("マニフェストパス検証エラー: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(manifestPath), 0755); err != nil {
		return fmt.Errorf("マニフェストディレクトリ作成エラー: %w", err)
	}

	data, err := json.Marshal(session)
	if err != nil {
		return fmt.Errorf("マニフェストエンコードエラー: %w", err)
	}

	return AtomicWriteFile(manifestPath, data)
}

// LoadPersistedSessions uploads 配下のマニフェストをすべて読み込む。
// 壊れた1件が他のセッションの復元を止めないよう、読めないものは読み飛ばす。
func LoadPersistedSessions() ([]*models.UploadSession, error) {
	entries, err := os.ReadDir(uploadsRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("uploadsディレクトリ読み込みエラー: %w", err)
	}

	sessions := make([]*models.UploadSession, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		manifestPath, pathErr := SafeSessionFilePath(entry.Name(), sessionManifestName)
		if pathErr != nil {
			continue
		}

		data, readErr := os.ReadFile(manifestPath)
		if readErr != nil {
			continue
		}

		var session models.UploadSession
		if unmarshalErr := json.Unmarshal(data, &session); unmarshalErr != nil {
			continue
		}

		// ディレクトリ名とマニフェスト内のIDが食い違うものは信用しない
		if session.ID != entry.Name() {
			continue
		}

		if session.UploadedChunks == nil {
			session.UploadedChunks = make(map[int]models.ChunkInfo)
		}

		sessions = append(sessions, &session)
	}

	return sessions, nil
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
	chunkFilePath, err := SafeSessionFilePath(sessionID, chunkFileName)
	if err != nil {
		return false, fmt.Errorf("チャンクファイルパス検証エラー: %w", err)
	}

	_, err = os.Stat(chunkFilePath)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
}
