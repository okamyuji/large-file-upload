package utils

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"large-file-upload-server/models"
)

// newTestStore parent/uploads を Root として開く。parent 側に置いたファイルで「外へ出られない」ことを確かめる。
func newTestStore(t *testing.T) (*Store, string) {
	t.Helper()

	parent := t.TempDir()
	uploads := filepath.Join(parent, "uploads")
	if err := os.Mkdir(uploads, 0o750); err != nil {
		t.Fatalf("uploads作成に失敗: %v", err)
	}
	root, err := os.OpenRoot(uploads)
	if err != nil {
		t.Fatalf("Root を開けません: %v", err)
	}
	t.Cleanup(func() { _ = root.Close() })

	return NewStore(root), parent
}

func assertNotExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("%s が存在します (err=%v)", path, err)
	}
}

// 検証関数を通さず Root 相対の関数を直接呼んでも、uploads の外には何も作れない。
func TestStoreRejectsEscapeEvenWhenValidationIsBypassed(t *testing.T) {
	store, parent := newTestStore(t)

	secret := filepath.Join(parent, "secret.txt")
	if err := os.WriteFile(secret, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Run("atomicWrite は ../x を作らない", func(t *testing.T) {
		if err := store.atomicWrite("../x", []byte("data")); err == nil {
			t.Fatal("エラーを期待したが nil")
		}
		assertNotExist(t, filepath.Join(parent, "x"))
	})

	t.Run("combine は ../x を作らない", func(t *testing.T) {
		if err := store.combine("../x", nil); err == nil {
			t.Fatal("エラーを期待したが nil")
		}
		assertNotExist(t, filepath.Join(parent, "x"))
	})

	t.Run("combine は外のファイルをチャンクとして読まない", func(t *testing.T) {
		if err := os.WriteFile(filepath.Join(store.rootDirForTest(t), "ok"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := store.combine("final", []string{"../secret.txt"}); err == nil {
			t.Fatal("エラーを期待したが nil")
		}
		assertNotExist(t, filepath.Join(store.rootDirForTest(t), "final"))
	})

	t.Run("acquireLock は ../x.lock を作らない", func(t *testing.T) {
		if _, err := store.acquireLock("../x.lock", time.Second); err == nil {
			t.Fatal("エラーを期待したが nil")
		}
		assertNotExist(t, filepath.Join(parent, "x.lock"))
	})

	t.Run("checksum は外のファイルを読まない", func(t *testing.T) {
		if _, err := store.checksum("../secret.txt"); err == nil {
			t.Fatal("エラーを期待したが nil")
		}
	})

	t.Run("loadManifest は外のディレクトリを読まない", func(t *testing.T) {
		if got := store.loadManifest(".."); got != nil {
			t.Fatalf("nil を期待したが %v", got)
		}
	})

	t.Run("記録済みパスの変換は uploads 外を拒否する", func(t *testing.T) {
		for _, p := range []string{"uploads/../x", "../x", "/etc/passwd", "other/x", "uploads/../../x"} {
			if _, err := store.rel(p); err == nil {
				t.Errorf("rel(%q) がエラーを返さない", p)
			}
		}
		if err := store.AtomicWriteFile("uploads/../x", []byte("d")); err == nil {
			t.Error("AtomicWriteFile が uploads 外を拒否しない")
		}
		assertNotExist(t, filepath.Join(parent, "x"))
	})

	t.Run("CleanupWorkingDirectory は uploads 自体を消さない", func(t *testing.T) {
		for _, p := range []string{"", ".", "/", "uploads", "uploads/", "../uploads"} {
			if err := store.CleanupWorkingDirectory(p); err == nil {
				t.Errorf("CleanupWorkingDirectory(%q) がエラーを返さない", p)
			}
		}
	})
}

func TestStoreRejectsSymlinkEscape(t *testing.T) {
	store, parent := newTestStore(t)
	outside := filepath.Join(parent, "outside")
	if err := os.Mkdir(outside, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(store.rootDirForTest(t), "link")); err != nil {
		t.Fatal(err)
	}

	if err := store.atomicWrite("link/x", []byte("data")); err == nil {
		t.Fatal("シンボリックリンク経由の書き込みが成功した")
	}
	entries, _ := os.ReadDir(outside)
	if len(entries) != 0 {
		t.Fatalf("uploads の外にファイルができた: %v", entries)
	}
}

func TestStoreCreatesFilesWithRestrictedModes(t *testing.T) {
	// umask の影響を除いて、コードが指定した権限そのものを確かめる
	old := syscall.Umask(0)
	t.Cleanup(func() { syscall.Umask(old) })

	store, _ := newTestStore(t)
	base := store.rootDirForTest(t)

	workingDir, err := store.CreateWorkingDirectory("session_1_abc")
	if err != nil {
		t.Fatalf("CreateWorkingDirectory: %v", err)
	}
	if workingDir != filepath.Join("uploads", "session_1_abc") {
		t.Fatalf("workingDir = %q", workingDir)
	}
	assertMode(t, filepath.Join(base, "session_1_abc"), 0o750)

	lock, err := store.AcquireChunkLock("session_1_abc", 0, time.Second)
	if err != nil {
		t.Fatalf("AcquireChunkLock: %v", err)
	}
	assertMode(t, filepath.Join(base, "session_1_abc", "chunk_0.lock"), 0o600)
	if err := lock.Release(); err != nil {
		t.Fatalf("Release: %v", err)
	}
	assertNotExist(t, filepath.Join(base, "session_1_abc", "chunk_0.lock"))

	chunkPath := filepath.Join(workingDir, "chunk_0.dat")
	if err := store.AtomicChunkWrite(chunkPath, []byte("abc")); err != nil {
		t.Fatalf("AtomicChunkWrite: %v", err)
	}
	assertMode(t, filepath.Join(base, "session_1_abc", "chunk_0.dat"), 0o600)

	session := &models.UploadSession{
		ID: "session_1_abc", FileName: "out.bin", WorkingDir: workingDir, TotalChunks: 1,
		UploadedChunks: map[int]models.ChunkInfo{0: {FilePath: chunkPath}},
	}
	final, err := store.CombineChunks(session)
	if err != nil {
		t.Fatalf("CombineChunks: %v", err)
	}
	assertMode(t, filepath.Join(base, "session_1_abc", "out.bin"), 0o600)
	sum, err := store.CalculateFileChecksum(final)
	if err != nil || sum != CalculateChecksum([]byte("abc")) {
		t.Fatalf("checksum = %q, err = %v", sum, err)
	}

	if err := store.SaveSessionManifest(session); err != nil {
		t.Fatalf("SaveSessionManifest: %v", err)
	}
	assertMode(t, filepath.Join(base, "session_1_abc", "session.json"), 0o600)
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s の権限 = %#o, 期待値 %#o", path, got, want)
	}
}

func TestStoreLifecycle(t *testing.T) {
	store, _ := newTestStore(t)

	if _, err := store.CreateWorkingDirectory("../etc"); err == nil {
		t.Fatal("不正なセッションIDを拒否しなかった")
	}

	workingDir, err := store.CreateWorkingDirectory("s1")
	if err != nil {
		t.Fatal(err)
	}

	exists, err := store.CheckChunkExists("s1", 0)
	if err != nil || exists {
		t.Fatalf("exists=%v err=%v", exists, err)
	}
	if err := store.AtomicWriteFile(filepath.Join(workingDir, "chunk_0.dat"), []byte("x")); err != nil {
		t.Fatal(err)
	}
	if exists, _ = store.CheckChunkExists("s1", 0); !exists {
		t.Fatal("書き込み後にチャンクが存在しない")
	}
	if _, err := store.CheckChunkExists("../s1", 0); err == nil {
		t.Fatal("不正なセッションIDを拒否しなかった")
	}

	// 書きかけの一時ファイルだけが消える
	stale := filepath.Join(workingDir, "chunk_1.dat.tmp.deadbeef")
	if err := store.AtomicWriteFile(filepath.Join(workingDir, "keep.dat"), []byte("k")); err != nil {
		t.Fatal(err)
	}
	if err := store.AtomicWriteFile(stale, []byte("t")); err != nil {
		t.Fatal(err)
	}
	store.CleanupStaleTempFiles(workingDir, "keep.dat")
	if _, err := store.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("一時ファイルが残っている: %v", err)
	}
	if _, err := store.Stat(filepath.Join(workingDir, "keep.dat")); err != nil {
		t.Fatalf("通常ファイルが消えた: %v", err)
	}
	// 名前に ".tmp." や ".combining." を含む完成ファイルは、一時ファイルではないので残す
	for _, name := range []string{"backup.tmp.zip", "x.combining.tar", "a.dat.tmp.deadbee", "a.dat.tmp.DEADBEEF"} {
		if err := store.AtomicWriteFile(filepath.Join(workingDir, name), []byte("f")); err != nil {
			t.Fatal(err)
		}
	}
	store.CleanupStaleTempFiles(workingDir, "keep.dat")
	for _, name := range []string{"backup.tmp.zip", "x.combining.tar", "a.dat.tmp.deadbee", "a.dat.tmp.DEADBEEF"} {
		if _, err := store.Stat(filepath.Join(workingDir, name)); err != nil {
			t.Fatalf("一時ファイルでない %s が消えた: %v", name, err)
		}
	}
	// 完成ファイルの名前が一時ファイルの接尾辞と同じ形でも、そのセッションの完成ファイルは残す
	final := filepath.Join(workingDir, "backup.tmp.deadbeef")
	staleNext := filepath.Join(workingDir, "chunk_2.dat.tmp.cafebabe")
	for _, f := range []string{final, staleNext} {
		if err := store.AtomicWriteFile(f, []byte("f")); err != nil {
			t.Fatal(err)
		}
	}
	store.CleanupStaleTempFiles(workingDir, "backup.tmp.deadbeef")
	if _, err := store.Stat(final); err != nil {
		t.Fatalf("完成ファイルが消えた: %v", err)
	}
	if _, err := store.Stat(staleNext); !os.IsNotExist(err) {
		t.Fatalf("一時ファイルが残っている: %v", err)
	}

	// マニフェストの往復。ID がディレクトリ名と食い違うものは読み込まない
	good := &models.UploadSession{ID: "s1", FileName: "a.bin"}
	if err := store.SaveSessionManifest(good); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateWorkingDirectory("s2"); err != nil {
		t.Fatal(err)
	}
	if err := store.AtomicWriteFile("uploads/s2/session.json", []byte(`{"id":"other"}`)); err != nil {
		t.Fatal(err)
	}
	sessions, err := store.LoadPersistedSessions()
	if err != nil || len(sessions) != 1 || sessions[0].ID != "s1" || sessions[0].UploadedChunks == nil {
		t.Fatalf("sessions=%v err=%v", sessions, err)
	}

	if err := store.Remove(filepath.Join(workingDir, "keep.dat")); err != nil {
		t.Fatal(err)
	}
	if err := store.CleanupWorkingDirectory(workingDir); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Stat(workingDir); !os.IsNotExist(err) {
		t.Fatalf("作業ディレクトリが残っている: %v", err)
	}
}

func TestCombineChunksReportsMissingChunk(t *testing.T) {
	store, _ := newTestStore(t)
	workingDir, _ := store.CreateWorkingDirectory("s1")
	session := &models.UploadSession{
		FileName: "a.bin", WorkingDir: workingDir, TotalChunks: 2,
		UploadedChunks: map[int]models.ChunkInfo{},
	}
	if _, err := store.CombineChunks(session); err == nil || !strings.Contains(err.Error(), "チャンク 0") {
		t.Fatalf("err = %v", err)
	}
}

// rootDirForTest Root の実パスを返す。
func (s *Store) rootDirForTest(t *testing.T) string {
	t.Helper()
	return s.root.Name()
}

func TestOpenStoreCreatesUploadsDirectory(t *testing.T) {
	old := syscall.Umask(0)
	t.Cleanup(func() { syscall.Umask(old) })
	t.Chdir(t.TempDir())

	store, err := OpenStore()
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	assertMode(t, "uploads", 0o750)

	sessions, err := store.LoadPersistedSessions()
	if err != nil || len(sessions) != 0 {
		t.Fatalf("sessions=%v err=%v", sessions, err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
}

func TestStoreRejectsOutsidePathsForStatRemoveChecksum(t *testing.T) {
	store, _ := newTestStore(t)
	if _, err := store.Stat("../x"); err == nil {
		t.Error("Stat が uploads 外を拒否しない")
	}
	if err := store.Remove("../x"); err == nil {
		t.Error("Remove が uploads 外を拒否しない")
	}
	if _, err := store.CalculateFileChecksum("../x"); err == nil {
		t.Error("CalculateFileChecksum が uploads 外を拒否しない")
	}
	if _, err := store.AcquireChunkLock("../x", 0, time.Second); err == nil {
		t.Error("AcquireChunkLock が不正なIDを拒否しない")
	}
	if err := store.SaveSessionManifest(&models.UploadSession{ID: "../x"}); err == nil {
		t.Error("SaveSessionManifest が不正なIDを拒否しない")
	}
	if _, err := store.CalculateFileChecksum("uploads/missing"); err == nil {
		t.Error("存在しないファイルでエラーにならない")
	}
}

func TestAcquireChunkLockTimesOutWhileHeld(t *testing.T) {
	store, _ := newTestStore(t)
	if _, err := store.CreateWorkingDirectory("s1"); err != nil {
		t.Fatal(err)
	}

	first, err := store.AcquireChunkLock("s1", 0, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.AcquireChunkLock("s1", 0, 100*time.Millisecond); err == nil {
		t.Fatal("保持中のロックが取得できてしまった")
	}
	if err := first.Release(); err != nil {
		t.Fatal(err)
	}
	if err := (&ChunkLock{}).Release(); err != nil {
		t.Fatalf("空のロックの Release: %v", err)
	}
}

func TestAtomicWriteFileFailsWithoutParentDirectory(t *testing.T) {
	store, _ := newTestStore(t)
	if err := store.AtomicWriteFile("uploads/nodir/x", []byte("d")); err == nil {
		t.Fatal("親ディレクトリが無いのに成功した")
	}
	if err := store.CleanupWorkingDirectory("uploads/never-created"); err != nil {
		t.Fatalf("存在しないディレクトリの削除はエラーにしない: %v", err)
	}
	if err := store.combine("nodir/final", nil); err == nil {
		t.Fatal("親ディレクトリが無いのに成功した")
	}
}
