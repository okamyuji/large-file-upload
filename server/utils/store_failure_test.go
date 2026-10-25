package utils

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"large-file-upload-server/models"
)

func skipIfRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root は権限エラーを起こせない")
	}
}

func TestOpenStore_failsWhenUploadsIsAFile(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.WriteFile("uploads", []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	store, err := OpenStore()

	if err == nil || store != nil || !strings.Contains(err.Error(), "作成エラー") {
		t.Fatalf("store=%v err=%v", store, err)
	}
}

func TestOpenStore_failsWhenUploadsIsNotReadable(t *testing.T) {
	skipIfRoot(t)
	t.Chdir(t.TempDir())
	if err := os.Mkdir("uploads", 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod("uploads", 0o750) })

	store, err := OpenStore()

	if err == nil || store != nil || !strings.Contains(err.Error(), "開けません") {
		t.Fatalf("store=%v err=%v", store, err)
	}
}

func TestRelease_failsWhenLockFileAlreadyClosed(t *testing.T) {
	store, _ := newTestStore(t)
	if _, err := store.CreateWorkingDirectory("s1"); err != nil {
		t.Fatal(err)
	}
	lock, err := store.AcquireChunkLock("s1", 0, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = lock.LockFile.Close()

	err = lock.Release()

	if err == nil || !strings.Contains(err.Error(), "ロック解放エラー") {
		t.Fatalf("err = %v", err)
	}
}

func TestRelease_failsWhenRootClosedBeforeRemove(t *testing.T) {
	store, _ := newTestStore(t)
	if _, err := store.CreateWorkingDirectory("s1"); err != nil {
		t.Fatal(err)
	}
	lock, err := store.AcquireChunkLock("s1", 0, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	err = lock.Release()

	if err == nil || !strings.Contains(err.Error(), "ロックファイル削除エラー") {
		t.Fatalf("err = %v", err)
	}
}

func TestRelease_ignoresLockFileAlreadyRemoved(t *testing.T) {
	store, _ := newTestStore(t)
	if _, err := store.CreateWorkingDirectory("s1"); err != nil {
		t.Fatal(err)
	}
	lock, err := store.AcquireChunkLock("s1", 0, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Remove(filepath.Join(uploadsRoot, lock.FilePath)); err != nil {
		t.Fatal(err)
	}

	if err := lock.Release(); err != nil {
		t.Fatalf("err = %v", err)
	}
}

func TestAtomicWriteFile_leavesNoTempFileWhenRenameFails(t *testing.T) {
	store, _ := newTestStore(t)
	// 空でないディレクトリへ rename すると失敗する
	if err := store.root.MkdirAll("target/inner", 0o750); err != nil {
		t.Fatal(err)
	}

	err := store.AtomicWriteFile("uploads/target", []byte("data"))

	if err == nil || !strings.Contains(err.Error(), "ファイル移動エラー") {
		t.Fatalf("err = %v", err)
	}
	entries, readErr := os.ReadDir(store.rootDirForTest(t))
	if readErr != nil {
		t.Fatal(readErr)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp.") {
			t.Fatalf("一時ファイルが残った: %s", e.Name())
		}
	}
}

func TestSaveSessionManifest_failsWhenSessionPathIsAFile(t *testing.T) {
	store, _ := newTestStore(t)
	if err := os.WriteFile(filepath.Join(store.rootDirForTest(t), "s1"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := store.SaveSessionManifest(&models.UploadSession{ID: "s1"})

	if err == nil || !strings.Contains(err.Error(), "マニフェストディレクトリ作成エラー") {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadPersistedSessions_failsWhenRootClosed(t *testing.T) {
	store, _ := newTestStore(t)
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	sessions, err := store.LoadPersistedSessions()

	if err == nil || sessions != nil || !strings.Contains(err.Error(), "読み込みエラー") {
		t.Fatalf("sessions=%v err=%v", sessions, err)
	}
}

func TestLoadPersistedSessions_returnsNothingWhenUploadsDirRemoved(t *testing.T) {
	store, _ := newTestStore(t)
	if err := os.RemoveAll(store.rootDirForTest(t)); err != nil {
		t.Fatal(err)
	}

	sessions, err := store.LoadPersistedSessions()

	if len(sessions) != 0 {
		t.Fatalf("sessions=%v err=%v", sessions, err)
	}
}

func TestLoadPersistedSessions_skipsUntrustedEntries(t *testing.T) {
	store, _ := newTestStore(t)
	base := store.rootDirForTest(t)
	good := &models.UploadSession{ID: "good"}
	if err := store.SaveSessionManifest(good); err != nil {
		t.Fatal(err)
	}
	mustMkdir := func(name string) string {
		dir := filepath.Join(base, name)
		if err := os.Mkdir(dir, 0o750); err != nil {
			t.Fatal(err)
		}
		return dir
	}
	write := func(path, body string) {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(base, "stray.txt"), "not a dir")
	write(filepath.Join(mustMkdir("corrupt"), sessionManifestName), "{broken")
	mustMkdir("no-manifest")
	mismatch, _ := json.Marshal(&models.UploadSession{ID: "other"})
	write(filepath.Join(mustMkdir("mismatch"), sessionManifestName), string(mismatch))
	mustMkdir("bad name")

	sessions, err := store.LoadPersistedSessions()

	if err != nil || len(sessions) != 1 || sessions[0].ID != "good" {
		t.Fatalf("sessions=%v err=%v", sessions, err)
	}
	if sessions[0].UploadedChunks == nil {
		t.Fatal("UploadedChunks が nil のまま")
	}
}

func TestCheckChunkExists_reportsUnexpectedStatError(t *testing.T) {
	store, _ := newTestStore(t)
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	exists, err := store.CheckChunkExists("s1", 0)

	if err == nil || exists {
		t.Fatalf("exists=%v err=%v", exists, err)
	}
}

// ファイルサイズ上限 (RLIMIT_FSIZE) を超える書き込みで write を実際に失敗させる。
// Go は SIGXFSZ を無視するので、プロセスは落ちず EFBIG が返る。soft limit だけ下げて後で戻す。
func TestAtomicWriteFile_removesTempFileWhenWriteFails(t *testing.T) {
	store, _ := newTestStore(t)
	var old syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_FSIZE, &old); err != nil {
		t.Skipf("Getrlimit: %v", err)
	}
	limited := syscall.Rlimit{Cur: 16, Max: old.Max}
	if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &limited); err != nil {
		t.Skipf("Setrlimit: %v", err)
	}
	t.Cleanup(func() { _ = syscall.Setrlimit(syscall.RLIMIT_FSIZE, &old) })

	err := store.AtomicWriteFile("uploads/big", make([]byte, 4096))

	if err == nil || !strings.Contains(err.Error(), "一時ファイル書き込みエラー") {
		t.Fatalf("err = %v", err)
	}
	entries, readErr := os.ReadDir(store.rootDirForTest(t))
	if readErr != nil || len(entries) != 0 {
		t.Fatalf("entries=%v err=%v", entries, readErr)
	}
}
