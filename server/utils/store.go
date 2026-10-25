package utils

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"large-file-upload-server/models"
)

const (
	// lockPollInterval ロック取得を再試行する間隔
	lockPollInterval = 5 * time.Millisecond

	// dirPerm uploads 配下のディレクトリの権限。サーバプロセスのユーザーだけが使う。
	dirPerm os.FileMode = 0o750
	// filePerm uploads 配下に作るファイルの権限。
	filePerm os.FileMode = 0o600
)

// Store uploads ディレクトリを *os.Root として開いたハンドル。
// ファイル操作はすべて Root 経由で行うので、相対パスが ".." やシンボリックリンクで
// uploads の外へ出ることを OS 側が拒否する。入力検証 (SafeSessionFilePath,
// ValidateFileName) が将来壊れても、書き込み先は uploads の内側に閉じる。
//
// セッションやチャンクが記録するパスは "uploads/<id>/..." 形式のまま保つ
// (永続化済みマニフェストとの互換のため)。Root に渡す前に rel で相対化する。
type Store struct {
	root *os.Root
}

// OpenStore カレントディレクトリ直下の uploads を作成して開く。
func OpenStore() (*Store, error) {
	if err := os.MkdirAll(uploadsRoot, dirPerm); err != nil {
		return nil, fmt.Errorf("uploadsディレクトリ作成エラー: %w", err)
	}
	root, err := os.OpenRoot(uploadsRoot)
	if err != nil {
		return nil, fmt.Errorf("uploadsディレクトリを開けません: %w", err)
	}
	return &Store{root: root}, nil
}

// NewStore 既に開いている Root から Store を作る。テストが独自のルートを渡すために使う。
func NewStore(root *os.Root) *Store {
	return &Store{root: root}
}

// Close Root を閉じる。
func (s *Store) Close() error {
	return s.root.Close()
}

// rel "uploads/<...>" 形式のパスを Root からの相対パスへ変換する。
// uploads の外を指すパスは Root に渡す前に拒否する。
func (s *Store) rel(stored string) (string, error) {
	cleaned := filepath.Clean(stored)
	if cleaned == uploadsRoot {
		return ".", nil
	}
	r, ok := strings.CutPrefix(cleaned, uploadsRoot+string(os.PathSeparator))
	if !ok || !filepath.IsLocal(r) {
		return "", fmt.Errorf("パスがアップロードディレクトリ外を指しています: %q", stored)
	}
	return r, nil
}

// sessionRel セッション配下のファイルの Root 相対パスを検証付きで返す。
func (s *Store) sessionRel(sessionID, fileName string) (string, error) {
	stored, err := SafeSessionFilePath(sessionID, fileName)
	if err != nil {
		return "", err
	}
	return s.rel(stored)
}

// CalculateFileChecksum ファイルのSHA256チェックサムを計算
func (s *Store) CalculateFileChecksum(stored string) (string, error) {
	rel, err := s.rel(stored)
	if err != nil {
		return "", err
	}
	return s.checksum(rel)
}

func (s *Store) checksum(rel string) (string, error) {
	file, err := s.root.Open(rel)
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

// CreateWorkingDirectory セッション用の作業ディレクトリを作成し、"uploads/<id>" 形式のパスを返す。
func (s *Store) CreateWorkingDirectory(sessionID string) (string, error) {
	rel, err := s.sessionRel(sessionID, "")
	if err != nil {
		return "", fmt.Errorf("作業ディレクトリ作成エラー: %w", err)
	}
	if err := s.root.MkdirAll(rel, dirPerm); err != nil {
		return "", fmt.Errorf("作業ディレクトリ作成エラー: %w", err)
	}
	return filepath.Join(uploadsRoot, rel), nil
}

// CleanupWorkingDirectory 作業ディレクトリとその中身を削除
func (s *Store) CleanupWorkingDirectory(workingDir string) error {
	rel, err := s.rel(workingDir)
	if err != nil || rel == "." {
		return fmt.Errorf("安全でないディレクトリパス: %s", workingDir)
	}
	return s.root.RemoveAll(rel)
}

// Stat 記録済みパスのファイル情報を取得
func (s *Store) Stat(stored string) (fs.FileInfo, error) {
	rel, err := s.rel(stored)
	if err != nil {
		return nil, err
	}
	return s.root.Stat(rel)
}

// Remove 記録済みパスのファイルを削除
func (s *Store) Remove(stored string) error {
	rel, err := s.rel(stored)
	if err != nil {
		return err
	}
	return s.root.Remove(rel)
}

// syncDir rename 自体を耐久化するため親ディレクトリも同期する
func (s *Store) syncDir(rel string) {
	if dir, err := s.root.Open(rel); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
}

// CombineChunks チャンクファイルを結合して最終ファイルを作成する。
//
// 一時ファイルへ書いて fsync してから rename で確定させる。この順序が要るのは、
// 呼び出し側が結合完了を completed として記録し、そのあとチャンクの実体を削除するためである。
// 最終ファイルの中身がディスクに届く前に completed だけが永続化されると、電源断のあとに
// 「完了と記録されているが中身が欠けていて、作り直す材料も無い」という復旧不能な状態が残る。
func (s *Store) CombineChunks(session *models.UploadSession) (string, error) {
	workingRel, err := s.rel(session.WorkingDir)
	if err != nil {
		return "", err
	}
	finalRel := filepath.Join(workingRel, session.FileName)

	chunkRels := make([]string, 0, session.TotalChunks)
	for i := 0; i < session.TotalChunks; i++ {
		chunkInfo, exists := session.UploadedChunks[i]
		if !exists {
			return "", fmt.Errorf("チャンク %d が見つかりません", i)
		}
		chunkRel, relErr := s.rel(chunkInfo.FilePath)
		if relErr != nil {
			return "", relErr
		}
		chunkRels = append(chunkRels, chunkRel)
	}

	if err := s.combine(finalRel, chunkRels); err != nil {
		return "", err
	}
	return filepath.Join(uploadsRoot, finalRel), nil
}

func (s *Store) combine(finalRel string, chunkRels []string) error {
	tempRel := finalRel + ".combining." + generateRandomString(8)

	finalFile, err := s.root.OpenFile(tempRel, os.O_WRONLY|os.O_CREATE|os.O_EXCL, filePerm)
	if err != nil {
		return fmt.Errorf("最終ファイル作成エラー: %w", err)
	}

	// チャンクを順序通りに結合
	combineErr := func() error {
		for i, chunkRel := range chunkRels {
			chunkFile, openErr := s.root.Open(chunkRel)
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
		_ = s.root.Remove(tempRel)
		return combineErr
	}

	if err := s.root.Rename(tempRel, finalRel); err != nil {
		_ = s.root.Remove(tempRel)
		return fmt.Errorf("最終ファイル確定エラー: %w", err)
	}

	s.syncDir(filepath.Dir(finalRel))
	return nil
}

// ChunkLock チャンクレベルのロック管理
type ChunkLock struct {
	LockFile *os.File
	// FilePath Root からの相対パス
	FilePath string
	root     *os.Root
}

// AcquireChunkLock チャンクの排他ロックを取得
func (s *Store) AcquireChunkLock(sessionID string, chunkIndex int, timeout time.Duration) (*ChunkLock, error) {
	lockRel, err := s.sessionRel(sessionID, fmt.Sprintf("chunk_%d.lock", chunkIndex))
	if err != nil {
		return nil, fmt.Errorf("ロックファイルパス検証エラー: %w", err)
	}
	return s.acquireLock(lockRel, timeout)
}

func (s *Store) acquireLock(lockRel string, timeout time.Duration) (*ChunkLock, error) {
	deadline := time.Now().Add(timeout)
	for {
		lockFile, err := s.openLockFile(lockRel, deadline)
		if err != nil {
			return nil, err
		}
		linked, err := s.waitForLock(lockFile, lockRel, deadline)
		if err != nil {
			_ = lockFile.Close()
			return nil, err
		}
		if linked {
			return &ChunkLock{LockFile: lockFile, FilePath: lockRel, root: s.root}, nil
		}
		// 前の持ち主が消したファイルのロックだった。閉じてロックを外し、今あるファイルで取り直す
		_ = lockFile.Close()
	}
}

// openLockFile ロックファイルを作成または開く。
// 解放がロックファイルを消すのと重なると、O_CREATE を付けても ENOENT が返ることがある
// (darwin で再現)。作業ディレクトリが残っている間は一時的な失敗として期限まで開き直す。
func (s *Store) openLockFile(lockRel string, deadline time.Time) (*os.File, error) {
	for {
		lockFile, err := s.root.OpenFile(lockRel, os.O_CREATE|os.O_RDWR, filePerm)
		if err == nil {
			return lockFile, nil
		}
		if !errors.Is(err, fs.ErrNotExist) || !time.Now().Before(deadline) || !s.dirExists(filepath.Dir(lockRel)) {
			return nil, fmt.Errorf("ロックファイル作成エラー: %w", err)
		}
		time.Sleep(lockPollInterval)
	}
}

func (s *Store) dirExists(rel string) bool {
	info, err := s.root.Stat(rel)
	return err == nil && info.IsDir()
}

// waitForLock lockFile の排他ロックを期限まで待つ。取れたロックが、今 lockRel にある
// ファイルのものかを返す。
// ブロッキングの flock を goroutine で待つと、タイムアウト後に fd を閉じる Close が
// その flock から戻るまで止まる (macOS で再現)。LOCK_NB で一定間隔に試して期限で打ち切る。
func (s *Store) waitForLock(lockFile *os.File, lockRel string, deadline time.Time) (bool, error) {
	for {
		err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return s.isLinked(lockFile, lockRel), nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			return false, fmt.Errorf("ロック取得エラー: %w", err)
		}
		if !time.Now().Before(deadline) {
			return false, errors.New("ロック取得タイムアウト")
		}
		time.Sleep(lockPollInterval)
	}
}

// isLinked 開いているファイルが、今 rel にあるファイルと同じものかを返す。
func (s *Store) isLinked(f *os.File, rel string) bool {
	held, err := f.Stat()
	if err != nil {
		return false
	}
	current, err := s.root.Stat(rel)
	return err == nil && os.SameFile(held, current)
}

// Release ロックを解放
func (cl *ChunkLock) Release() error {
	if cl.LockFile == nil {
		return nil
	}

	// ロックを持ったまま先に消す。消した後に来た要求は新しいファイルを作り、
	// 消えたファイルのロックを待っていた要求は isLinked で取り直すので、持ち主は常に1つになる。
	removeErr := cl.root.Remove(cl.FilePath)

	// ロック解放
	err := syscall.Flock(int(cl.LockFile.Fd()), syscall.LOCK_UN)
	if err != nil {
		_ = cl.LockFile.Close()
		return fmt.Errorf("ロック解放エラー: %w", err)
	}

	// ファイルクローズ
	closeErr := cl.LockFile.Close()

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
func (s *Store) AtomicWriteFile(stored string, data []byte) error {
	rel, err := s.rel(stored)
	if err != nil {
		return err
	}
	return s.atomicWrite(rel, data)
}

// AtomicChunkWrite 原子的なチャンク書き込み
func (s *Store) AtomicChunkWrite(stored string, data []byte) error {
	return s.AtomicWriteFile(stored, data)
}

func (s *Store) atomicWrite(rel string, data []byte) error {
	// 一時ファイルパスを生成
	tempRel := rel + ".tmp." + generateRandomString(8)

	// 一時ファイルに書き込み
	tempFile, err := s.root.OpenFile(tempRel, os.O_WRONLY|os.O_CREATE|os.O_EXCL, filePerm)
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
		_ = s.root.Remove(tempRel) // クリーンアップ
		return fmt.Errorf("一時ファイル書き込みエラー: %w", writeErr)
	}

	if syncErr != nil {
		_ = s.root.Remove(tempRel) // クリーンアップ
		return fmt.Errorf("一時ファイル同期エラー: %w", syncErr)
	}

	if closeErr != nil {
		_ = s.root.Remove(tempRel) // クリーンアップ
		return fmt.Errorf("一時ファイルクローズエラー: %w", closeErr)
	}

	// 一時ファイルを最終ファイルに原子的に移動
	if err := s.root.Rename(tempRel, rel); err != nil {
		_ = s.root.Remove(tempRel) // クリーンアップ
		return fmt.Errorf("ファイル移動エラー: %w", err)
	}

	s.syncDir(filepath.Dir(rel))
	return nil
}

// readDir Root 内のディレクトリ項目を列挙する。
func (s *Store) readDir(rel string) ([]fs.DirEntry, error) {
	dir, err := s.root.Open(rel)
	if err != nil {
		return nil, err
	}
	defer func() { _ = dir.Close() }()
	return dir.ReadDir(-1)
}

// CleanupStaleTempFiles セッションの作業ディレクトリに残った書きかけの一時ファイルを削除する。
//
// 結合中や原子的書き込みの最中にプロセスが落ちると、`.combining.*` や `.tmp.*` が残る。
// 結合の一時ファイルは最終ファイルと同じ大きさになり得るので、再起動のたびに積み上がると
// 作業領域を使い切り、既存セッションの結合も新規チャンクの受信も失敗するようになる。
// staleTempPattern combine と atomicWrite が付ける接尾辞だけに一致させる。
// ".tmp." を含むだけの名前（backup.tmp.zip など）は利用者の完成ファイルなので消さない。
var staleTempPattern = regexp.MustCompile(`\.(combining|tmp)\.[0-9a-f]{8}$`)

// finalName はそのセッションの完成ファイル名。利用者の付けた名前が接尾辞と同じ形でも消さない。
func (s *Store) CleanupStaleTempFiles(workingDir, finalName string) {
	dirRel, err := s.rel(workingDir)
	if err != nil {
		return
	}
	entries, err := s.readDir(dirRel)
	if err != nil {
		return
	}

	for _, entry := range entries {
		name := entry.Name()
		if name == finalName || !staleTempPattern.MatchString(name) {
			continue
		}
		if removeErr := s.root.Remove(filepath.Join(dirRel, name)); removeErr == nil {
			log.Printf("🧹 [CLEANUP] 書きかけの一時ファイルを削除: %s", strconv.Quote(filepath.Join(workingDir, name)))
		}
	}
}

// sessionManifestName セッション状態を保存するマニフェストのファイル名
const sessionManifestName = "session.json"

// SaveSessionManifest セッション状態を作業ディレクトリへ原子的に書き出す。
// サーバをSoTとして扱う以上、受信済みチャンクの記録はプロセスの寿命を越えて残る必要がある。
func (s *Store) SaveSessionManifest(session *models.UploadSession) error {
	manifestRel, err := s.sessionRel(session.ID, sessionManifestName)
	if err != nil {
		return fmt.Errorf("マニフェストパス検証エラー: %w", err)
	}

	if err := s.root.MkdirAll(filepath.Dir(manifestRel), dirPerm); err != nil {
		return fmt.Errorf("マニフェストディレクトリ作成エラー: %w", err)
	}

	data, err := json.Marshal(session)
	if err != nil {
		return fmt.Errorf("マニフェストエンコードエラー: %w", err)
	}

	return s.atomicWrite(manifestRel, data)
}

// LoadPersistedSessions uploads 配下のマニフェストをすべて読み込む。
// 壊れた1件が他のセッションの復元を止めないよう、読めないものは読み飛ばす。
func (s *Store) LoadPersistedSessions() ([]*models.UploadSession, error) {
	entries, err := s.readDir(".")
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
		if session := s.loadManifest(entry.Name()); session != nil {
			sessions = append(sessions, session)
		}
	}

	return sessions, nil
}

// loadManifest 1セッション分のマニフェストを読む。読めない・信用できないものは nil を返す。
func (s *Store) loadManifest(dirName string) *models.UploadSession {
	manifestRel, err := s.sessionRel(dirName, sessionManifestName)
	if err != nil {
		return nil
	}

	data, err := s.root.ReadFile(manifestRel)
	if err != nil {
		return nil
	}

	var session models.UploadSession
	if err := json.Unmarshal(data, &session); err != nil {
		return nil
	}

	// ディレクトリ名とマニフェスト内のIDが食い違うものは信用しない
	if session.ID != dirName {
		return nil
	}

	if session.UploadedChunks == nil {
		session.UploadedChunks = make(map[int]models.ChunkInfo)
	}
	return &session
}

// CheckChunkExists チャンクファイルの存在確認
func (s *Store) CheckChunkExists(sessionID string, chunkIndex int) (bool, error) {
	chunkRel, err := s.sessionRel(sessionID, fmt.Sprintf("chunk_%d.dat", chunkIndex))
	if err != nil {
		return false, fmt.Errorf("チャンクファイルパス検証エラー: %w", err)
	}

	_, err = s.root.Stat(chunkRel)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
}
