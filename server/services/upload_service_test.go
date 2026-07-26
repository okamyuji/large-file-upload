package services

import (
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"large-file-upload-server/models"
	"large-file-upload-server/utils"
)

// useTempUploadsDir uploads ディレクトリが相対パスなので、テストごとに作業ディレクトリを移す。
func useTempUploadsDir(t *testing.T) string {
	t.Helper()

	originalDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("作業ディレクトリ取得に失敗: %v", err)
	}

	tempDir := t.TempDir()
	if err := os.Chdir(tempDir); err != nil {
		t.Fatalf("作業ディレクトリ変更に失敗: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(originalDir) })

	return tempDir
}

// uploadAllChunks テスト用にファイル全体を chunkSize で分割して送り込む。
func uploadAllChunks(t *testing.T, service *UploadService, sessionID string, data []byte, chunkSize int) {
	t.Helper()

	for offset, index := 0, 0; offset < len(data); offset, index = offset+chunkSize, index+1 {
		end := offset + chunkSize
		if end > len(data) {
			end = len(data)
		}
		chunk := data[offset:end]
		if err := service.UploadChunk(sessionID, index, chunk, utils.CalculateChecksum(chunk)); err != nil {
			t.Fatalf("チャンク %d の送信に失敗: %v", index, err)
		}
	}
}

// waitForStatus 結合は非同期なので、期待するステータスになるまで短く待つ。
func waitForStatus(t *testing.T, service *UploadService, sessionID string, want models.SessionStatus) *models.StatusResponse {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	var last *models.StatusResponse
	for time.Now().Before(deadline) {
		status, err := service.GetSessionStatus(sessionID)
		if err != nil {
			t.Fatalf("ステータス取得に失敗: %v", err)
		}
		last = status
		if status.Status == string(want) {
			return status
		}
		time.Sleep(20 * time.Millisecond)
	}

	t.Fatalf("ステータスが %s になりませんでした。最後の値: %s", want, last.Status)
	return nil
}

func newTestSession(t *testing.T, service *UploadService, data []byte, chunkSize int) *models.UploadSession {
	t.Helper()

	totalChunks := (len(data) + chunkSize - 1) / chunkSize
	session, err := service.CreateSession(&models.CreateSessionRequest{
		FileName:     "sample.bin",
		TotalChunks:  totalChunks,
		FileSize:     int64(len(data)),
		FileChecksum: utils.CalculateChecksum(data),
		ChunkSize:    chunkSize,
	})
	if err != nil {
		t.Fatalf("セッション作成に失敗: %v", err)
	}
	return session
}

// 最終チャンクが届いた時点で、クライアントの POST /complete を待たずに結合が終わること。
// バックグラウンドでサスペンドされたアプリが complete を呼べなくてもファイルが確定する、という保証。
func TestUploadChunkTriggersCombineWithoutCompleteCall(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadService()
	data := []byte(strings.Repeat("最終チャンク到達で自動結合されることを確認するテストデータ\n", 100))
	chunkSize := 1024

	session := newTestSession(t, service, data, chunkSize)
	uploadAllChunks(t, service, session.ID, data, chunkSize)

	status := waitForStatus(t, service, session.ID, models.StatusCompleted)
	if len(status.MissingChunks) != 0 {
		t.Fatalf("未受信チャンクが残っています: %v", status.MissingChunks)
	}

	stored, exists := service.GetSession(session.ID)
	if !exists {
		t.Fatal("完了後にセッションが消えています")
	}
	finalChecksum, err := utils.CalculateFileChecksum(stored.FinalFilePath)
	if err != nil {
		t.Fatalf("最終ファイルのチェックサム計算に失敗: %v", err)
	}
	if finalChecksum != stored.FileChecksum {
		t.Fatalf("最終ファイルの内容が一致しません。期待値: %s, 実際: %s", stored.FileChecksum, finalChecksum)
	}
}

// 結合済みのセッションに対する CompleteUpload は、何回呼んでも同じ結果を返すこと。
func TestCompleteUploadIsIdempotent(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadService()
	data := []byte(strings.Repeat("冪等性の確認用データ。complete を二度呼んでも結果は変わらない\n", 100))
	chunkSize := 1024

	session := newTestSession(t, service, data, chunkSize)
	uploadAllChunks(t, service, session.ID, data, chunkSize)
	waitForStatus(t, service, session.ID, models.StatusCompleted)

	first, err := service.CompleteUpload(session.ID)
	if err != nil {
		t.Fatalf("1回目の complete に失敗: %v", err)
	}
	second, err := service.CompleteUpload(session.ID)
	if err != nil {
		t.Fatalf("2回目の complete に失敗: %v", err)
	}

	if first.FilePath != second.FilePath || first.Status != second.Status {
		t.Fatalf("complete の結果が呼び出しごとに変わりました: %+v / %+v", first, second)
	}
	if first.Status != string(models.StatusCompleted) {
		t.Fatalf("完了ステータスが返りませんでした: %s", first.Status)
	}
}

// プロセスを再起動しても、受信済みチャンクの記録がディスクから復元されること。
// これが無いとサーバをSoTとして扱えず、再起動のたびに全チャンクが再送される。
func TestSessionsSurviveServiceRestart(t *testing.T) {
	useTempUploadsDir(t)

	data := []byte(strings.Repeat("再起動をまたいで受信済みチャンクが残ることを確認するデータ\n", 100))
	chunkSize := 1024
	totalChunks := (len(data) + chunkSize - 1) / chunkSize

	service := NewUploadService()
	session := newTestSession(t, service, data, chunkSize)

	// 先頭2チャンクだけ送って中断した状態を作る
	for index := 0; index < 2; index++ {
		chunk := data[index*chunkSize : (index+1)*chunkSize]
		if err := service.UploadChunk(session.ID, index, chunk, utils.CalculateChecksum(chunk)); err != nil {
			t.Fatalf("チャンク %d の送信に失敗: %v", index, err)
		}
	}

	// プロセス再起動に相当する。新しいインスタンスがディスクから復元する。
	restarted := NewUploadService()
	status, err := restarted.GetSessionStatus(session.ID)
	if err != nil {
		t.Fatalf("再起動後のステータス取得に失敗: %v", err)
	}

	if status.UploadedChunks != 2 {
		t.Fatalf("受信済みチャンク数が復元されていません。期待値: 2, 実際: %d", status.UploadedChunks)
	}
	if len(status.MissingChunks) != totalChunks-2 {
		t.Fatalf("未受信チャンクの数が合いません。期待値: %d, 実際: %d", totalChunks-2, len(status.MissingChunks))
	}

	// 復元後に残りを送れば、そのまま結合まで到達すること
	for index := 2; index < totalChunks; index++ {
		end := (index + 1) * chunkSize
		if end > len(data) {
			end = len(data)
		}
		chunk := data[index*chunkSize : end]
		if err := restarted.UploadChunk(session.ID, index, chunk, utils.CalculateChecksum(chunk)); err != nil {
			t.Fatalf("復元後のチャンク %d 送信に失敗: %v", index, err)
		}
	}
	waitForStatus(t, restarted, session.ID, models.StatusCompleted)
}

// 並行してチャンクを送っても、完了記録が古い世代のマニフェストに上書きされないこと。
// 上書きされると、実体は結合済みなのに再起動で未完了として復元される。
func TestConcurrentChunksDoNotClobberCompletedManifest(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadService()
	data := []byte(strings.Repeat("並行送信でマニフェストが巻き戻らないことを確認するデータ\n", 400))
	chunkSize := 1024
	totalChunks := (len(data) + chunkSize - 1) / chunkSize

	session := newTestSession(t, service, data, chunkSize)

	var wg sync.WaitGroup
	for index := 0; index < totalChunks; index++ {
		end := (index + 1) * chunkSize
		if end > len(data) {
			end = len(data)
		}
		chunk := data[index*chunkSize : end]

		wg.Add(1)
		go func(i int, payload []byte) {
			defer wg.Done()
			if err := service.UploadChunk(session.ID, i, payload, utils.CalculateChecksum(payload)); err != nil {
				t.Errorf("チャンク %d の送信に失敗: %v", i, err)
			}
		}(index, chunk)
	}
	wg.Wait()

	waitForStatus(t, service, session.ID, models.StatusCompleted)

	// 再起動しても完了のまま復元されること
	restarted := NewUploadService()
	status, err := restarted.GetSessionStatus(session.ID)
	if err != nil {
		t.Fatalf("再起動後のステータス取得に失敗: %v", err)
	}
	if status.Status != string(models.StatusCompleted) {
		t.Fatalf("完了記録が巻き戻っています: %s", status.Status)
	}
}

// 期限切れの掃除が、未完了セッションと完了済みセッションで別の期限を使うこと。
// 同じ期限でまとめて消すと、確定させた成果物まで短時間で失われる。
func TestCleanupUsesSeparateRetentionForCompletedSessions(t *testing.T) {
	useTempUploadsDir(t)

	// 未完了は1ナノ秒で期限切れ、完了済みは十分長く保持する設定にする
	service := NewUploadServiceWithRetention(time.Nanosecond, time.Hour)

	data := []byte(strings.Repeat("保持期間の分離を検証するためのテストデータです\n", 100))
	chunkSize := 1024

	completed := newTestSession(t, service, data, chunkSize)
	uploadAllChunks(t, service, completed.ID, data, chunkSize)
	waitForStatus(t, service, completed.ID, models.StatusCompleted)

	incomplete := newTestSession(t, service, data, chunkSize)
	chunk := data[0:chunkSize]
	if err := service.UploadChunk(incomplete.ID, 0, chunk, utils.CalculateChecksum(chunk)); err != nil {
		t.Fatalf("未完了セッションのチャンク送信に失敗: %v", err)
	}

	time.Sleep(5 * time.Millisecond)
	deleted := service.CleanupExpiredSessions()

	if _, exists := service.GetSession(incomplete.ID); exists {
		t.Fatal("未完了セッションが期限切れで削除されていません")
	}
	stored, exists := service.GetSession(completed.ID)
	if !exists {
		t.Fatal("完了済みセッションが未完了と同じ期限で削除されました")
	}
	if _, err := os.Stat(stored.FinalFilePath); err != nil {
		t.Fatalf("完了済みセッションの最終ファイルが消えています: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("削除件数が想定と違います。期待値: 1, 実際: %d", deleted)
	}
}

// GET /status が再開可能期限を返すこと。クライアントが404の理由を判別する材料になる。
func TestStatusReportsExpiry(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadServiceWithRetention(2*time.Hour, 48*time.Hour)
	data := []byte(strings.Repeat("再開可能期限の提示を検証するデータ\n", 100))
	chunkSize := 1024

	session := newTestSession(t, service, data, chunkSize)
	status, err := service.GetSessionStatus(session.ID)
	if err != nil {
		t.Fatalf("ステータス取得に失敗: %v", err)
	}

	if status.ExpiresAt.IsZero() {
		t.Fatal("再開可能期限が返っていません")
	}
	if status.ExpiresAt.Before(time.Now().Add(time.Hour)) {
		t.Fatalf("未完了セッションの期限が短すぎます: %s", status.ExpiresAt)
	}
}

// 同じ番号に中身の違うチャンクが再送されたら、保存済みを置き換えて結合まで到達すること。
// 番号だけで「受け取り済み」と判断すると、最初に誤った内容が入った時点で復旧できなくなる。
func TestDuplicateChunkWithDifferentContentIsReplaced(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadService()
	data := []byte(strings.Repeat("再送で中身が置き換わることを確認するためのテストデータ\n", 100))
	chunkSize := 1024
	totalChunks := (len(data) + chunkSize - 1) / chunkSize

	session := newTestSession(t, service, data, chunkSize)

	// 先頭チャンクだけ誤った内容で先に保存させる
	wrongChunk := []byte(strings.Repeat("X", chunkSize))
	if err := service.UploadChunk(session.ID, 0, wrongChunk, utils.CalculateChecksum(wrongChunk)); err != nil {
		t.Fatalf("誤った内容の送信に失敗: %v", err)
	}

	// 正しい内容で再送する。ここで捨てられると最終チェックサム検証が永久に失敗する。
	correctChunk := data[0:chunkSize]
	if err := service.UploadChunk(session.ID, 0, correctChunk, utils.CalculateChecksum(correctChunk)); err != nil {
		t.Fatalf("正しい内容の再送が拒否されました: %v", err)
	}

	for index := 1; index < totalChunks; index++ {
		end := (index + 1) * chunkSize
		if end > len(data) {
			end = len(data)
		}
		chunk := data[index*chunkSize : end]
		if err := service.UploadChunk(session.ID, index, chunk, utils.CalculateChecksum(chunk)); err != nil {
			t.Fatalf("チャンク %d の送信に失敗: %v", index, err)
		}
	}

	waitForStatus(t, service, session.ID, models.StatusCompleted)
}

// 中身が同一の再送は置き換えず、既にアップロード済みとして扱うこと。
func TestDuplicateChunkWithSameContentIsTreatedAsUploaded(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadService()
	data := []byte(strings.Repeat("同一内容の再送が冪等であることを確認するデータ\n", 100))
	chunkSize := 1024

	session := newTestSession(t, service, data, chunkSize)
	chunk := data[0:chunkSize]
	checksum := utils.CalculateChecksum(chunk)

	if err := service.UploadChunk(session.ID, 0, chunk, checksum); err != nil {
		t.Fatalf("1回目の送信に失敗: %v", err)
	}

	err := service.UploadChunk(session.ID, 0, chunk, checksum)
	if err == nil || !strings.Contains(err.Error(), "既にアップロード済み") {
		t.Fatalf("同一内容の再送が既存扱いになりませんでした: %v", err)
	}
}

// 完了と記録されているのに最終ファイルが消えていたら、復元時にエラーへ落とすこと。
// 完了を信じたままにすると、クライアントは手元のコピーを消して復旧できなくなる。
func TestRestoreMarksErrorWhenFinalFileIsMissing(t *testing.T) {
	useTempUploadsDir(t)

	service := NewUploadService()
	data := []byte(strings.Repeat("最終ファイルの実在確認を検証するためのテストデータ\n", 100))
	chunkSize := 1024

	session := newTestSession(t, service, data, chunkSize)
	uploadAllChunks(t, service, session.ID, data, chunkSize)
	waitForStatus(t, service, session.ID, models.StatusCompleted)

	stored, _ := service.GetSession(session.ID)
	if err := os.Remove(stored.FinalFilePath); err != nil {
		t.Fatalf("最終ファイル削除に失敗: %v", err)
	}

	restarted := NewUploadService()
	status, err := restarted.GetSessionStatus(session.ID)
	if err != nil {
		t.Fatalf("再起動後のステータス取得に失敗: %v", err)
	}
	if status.Status != string(models.StatusError) {
		t.Fatalf("最終ファイルが無いのに完了扱いのままです: %s", status.Status)
	}
}

// マニフェストに残っていてもチャンクの実体が消えていれば、未受信として扱い直すこと。
// ここを信用すると GET /status が嘘をつき、結合が必ず失敗する。
func TestRestoreDropsChunksWithoutFiles(t *testing.T) {
	useTempUploadsDir(t)

	data := []byte(strings.Repeat("実体が消えたチャンクを未受信に戻すことを確認するデータ\n", 100))
	chunkSize := 1024

	service := NewUploadService()
	session := newTestSession(t, service, data, chunkSize)

	chunk := data[0:chunkSize]
	if err := service.UploadChunk(session.ID, 0, chunk, utils.CalculateChecksum(chunk)); err != nil {
		t.Fatalf("チャンク0の送信に失敗: %v", err)
	}

	stored, _ := service.GetSession(session.ID)
	chunkPath := stored.UploadedChunks[0].FilePath
	if err := os.Remove(chunkPath); err != nil {
		t.Fatalf("チャンクファイル削除に失敗: %v", err)
	}

	restarted := NewUploadService()
	status, err := restarted.GetSessionStatus(session.ID)
	if err != nil {
		t.Fatalf("再起動後のステータス取得に失敗: %v", err)
	}
	if status.UploadedChunks != 0 {
		t.Fatalf("実体の無いチャンクが受信済みのまま残っています: %d", status.UploadedChunks)
	}
}
