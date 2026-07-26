package services

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"large-file-upload-server/models"
	"large-file-upload-server/utils"
)

// finalizeWaitTimeout POST /complete が結合完了を待つ上限。
// これを超えたら 202 相当の「結合中」を返し、クライアントには GET /status を見てもらう。
// HTTP サーバの WriteTimeout より短くしておかないと、待っている側が先に切れる。
const finalizeWaitTimeout = 20 * time.Second

// DefaultIncompleteSessionMaxAge 未完了セッションを保持する期間。
// これを過ぎると作業領域ごと削除し、クライアントから見ると再開先が404になる。
const DefaultIncompleteSessionMaxAge = 7 * 24 * time.Hour

// DefaultCompletedSessionMaxAge 完了済みセッションと結合後のファイルを保持する期間。
// 未完了と同じ期間で消すと、確定させた成果物が短時間で失われる。
const DefaultCompletedSessionMaxAge = 30 * 24 * time.Hour

// UploadService アップロードサービス
type UploadService struct {
	sessions    map[string]*models.UploadSession
	sessionsMux sync.RWMutex

	// 保持期間。未完了と完了済みで消していい理由が違うので分けて持つ。
	incompleteMaxAge time.Duration
	completedMaxAge  time.Duration

	// finalizing セッションごとの結合中フラグを兼ねた完了通知チャネル。
	// 結合は最終チャンク到達でサーバ側が自動的に始めるため、二重起動を
	// ここで止める。複数プロセスで動かすなら Redis か DB のロックに置き換える。
	finalizing    map[string]chan struct{}
	finalizingMux sync.Mutex

	// manifestMux セッションごとのマニフェスト書き込みロック。
	// スナップショット採取から rename までを直列化しないと、並行する複数チャンクの
	// 保存が追い越し合い、古い世代が新しい記録を上書きする。完了記録が巻き戻ると、
	// 実体は結合済みなのに未完了として復元される。
	manifestMux    map[string]*sync.Mutex
	manifestMuxMux sync.Mutex
}

// NewUploadService 新しいアップロードサービスを作成
func NewUploadService() *UploadService {
	return NewUploadServiceWithRetention(
		DefaultIncompleteSessionMaxAge,
		DefaultCompletedSessionMaxAge,
	)
}

// NewUploadServiceWithRetention 保持期間を明示してアップロードサービスを作成する。
func NewUploadServiceWithRetention(incompleteMaxAge, completedMaxAge time.Duration) *UploadService {
	service := &UploadService{
		sessions:         make(map[string]*models.UploadSession),
		finalizing:       make(map[string]chan struct{}),
		manifestMux:      make(map[string]*sync.Mutex),
		incompleteMaxAge: incompleteMaxAge,
		completedMaxAge:  completedMaxAge,
	}
	service.restorePersistedSessions()
	return service
}

// restorePersistedSessions 起動時にディスク上のマニフェストからセッションを復元する。
// サーバをSoTとして扱うには、プロセス再起動を越えて状態が残らなければ意味がない。
// 復元しないと再起動後の GET /status が404になり、クライアントは再開先を失う。
func (s *UploadService) restorePersistedSessions() {
	sessions, err := utils.LoadPersistedSessions()
	if err != nil {
		log.Printf("⚠️ [RESTORE] セッション復元エラー: %v", err)
		return
	}

	resumable := make([]string, 0)
	for _, session := range sessions {
		if session.Status == models.StatusCompleted {
			// 完了と記録されていても実体を確かめる。結合済みのチャンクは削除されているため、
			// ここで嘘を通すとクライアントは完了を信じて手元のコピーまで消してしまう。
			// 全体の再ハッシュは数GBだと起動を止めてしまうので、存在とサイズの一致までを見る。
			if err := verifyFinalFile(session); err != nil {
				log.Printf("❌ [RESTORE] session=%s の最終ファイル検証に失敗: %v", session.ID, err)
				session.Status = models.StatusError
				session.FinalizeError = err.Error()
			}
		}

		if session.Status != models.StatusCompleted {
			// マニフェストに載っていても実体が消えているチャンクは未受信として扱う。
			// ここを怠ると GET /status が嘘の missingChunks を返し、結合が必ず失敗する。
			for index, info := range session.UploadedChunks {
				if _, statErr := os.Stat(info.FilePath); statErr != nil {
					log.Printf("⚠️ [RESTORE] session=%s chunk=%d の実体が無いため未受信に戻します", session.ID, index)
					delete(session.UploadedChunks, index)
				}
			}

			// 結合の途中でプロセスが落ちた場合は結合前の状態に戻し、やり直させる
			if session.Status == models.StatusCombining {
				session.Status = models.StatusReady
			}
		}

		// 前回の結合や書き込みの途中で落ちた痕跡を、結合を再開する前に片付ける
		utils.CleanupStaleTempFiles(session.WorkingDir)

		s.sessions[session.ID] = session
		if session.Status != models.StatusCompleted && session.IsComplete() && !session.FinalizeFatal {
			resumable = append(resumable, session.ID)
		}
	}

	if len(sessions) > 0 {
		log.Printf("♻️ [RESTORE] %d 件のセッションをディスクから復元しました", len(sessions))
	}

	// 全チャンクが揃ったまま結合されずに残っているセッションは、起動時にそのまま結合を再開する
	for _, sessionID := range resumable {
		log.Printf("♻️ [RESTORE] session=%s は全チャンク受信済み → 結合を再開します", sessionID)
		s.ensureFinalize(sessionID)
	}
}

// verifyFinalFile 完了と記録されたセッションの最終ファイルが実在し、想定サイズと一致するか確かめる。
func verifyFinalFile(session *models.UploadSession) error {
	if session.FinalFilePath == "" {
		return errors.New("完了と記録されていますが最終ファイルのパスがありません")
	}

	info, err := os.Stat(session.FinalFilePath)
	if err != nil {
		return fmt.Errorf("最終ファイルが見つかりません: %w", err)
	}

	if info.Size() != session.FileSize {
		return fmt.Errorf("最終ファイルのサイズが一致しません - 期待値: %d, 実際の値: %d", session.FileSize, info.Size())
	}

	return nil
}

// persistSession セッションの現在値をディスクへ書き出す。
// sessionsMux を保持したまま呼ばないこと。ディスク I/O をロック内に閉じ込めると
// 全セッションの status 取得までブロックしてしまう。
//
// 失敗をログだけで流さず呼び出し元へ返す。マニフェストが書けていないのに
// チャンクを受け取ったことにすると、再起動後に「実体はあるが未受信」あるいは
// 「完了と記録されているが実体が消えている」という復旧できない状態が残る。
func (s *UploadService) persistSession(session *models.UploadSession) error {
	// スナップショット採取と書き込みを1本の流れとして直列化する。ここを分けると、
	// 先に採取した古い内容が後から書かれて新しい記録を消してしまう。
	lock := s.manifestLock(session.ID)
	lock.Lock()
	defer lock.Unlock()

	s.sessionsMux.RLock()
	snapshot := session.Clone()
	s.sessionsMux.RUnlock()

	return s.writeManifest(snapshot)
}

// persistSnapshot 明示的に組み立てた状態を書き出す。
// 「耐久化してから、その状態を名乗る」順序が必要な場面で使う。
func (s *UploadService) persistSnapshot(snapshot *models.UploadSession) error {
	lock := s.manifestLock(snapshot.ID)
	lock.Lock()
	defer lock.Unlock()

	return s.writeManifest(snapshot)
}

// writeManifest 呼び出し側で manifestLock を保持した状態で呼ぶ。
func (s *UploadService) writeManifest(snapshot *models.UploadSession) error {
	if err := utils.SaveSessionManifest(snapshot); err != nil {
		log.Printf("⚠️ [PERSIST] session=%s マニフェスト保存エラー: %v", snapshot.ID, err)
		return err
	}
	return nil
}

// manifestLock セッション単位のマニフェスト書き込みロックを返す。
func (s *UploadService) manifestLock(sessionID string) *sync.Mutex {
	s.manifestMuxMux.Lock()
	defer s.manifestMuxMux.Unlock()

	if lock, exists := s.manifestMux[sessionID]; exists {
		return lock
	}
	lock := &sync.Mutex{}
	s.manifestMux[sessionID] = lock
	return lock
}

// releaseManifestLock セッション削除時にロックの記録も取り除く。
func (s *UploadService) releaseManifestLock(sessionID string) {
	s.manifestMuxMux.Lock()
	delete(s.manifestMux, sessionID)
	s.manifestMuxMux.Unlock()
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

	// 作成時点でマニフェストを残す。ここを飛ばすと、1チャンクも届かないうちに
	// 再起動したセッションが復元できず、クライアント側に孤立セッションが残る。
	if err := s.persistSession(session); err != nil {
		s.sessionsMux.Lock()
		delete(s.sessions, sessionID)
		s.sessionsMux.Unlock()
		_ = utils.CleanupWorkingDirectory(workingDir)
		return nil, fmt.Errorf("セッション情報の保存に失敗しました: %w", err)
	}

	return session, nil
}

// GetSession セッションを取得
func (s *UploadService) GetSession(sessionID string) (*models.UploadSession, bool) {
	s.sessionsMux.RLock()
	defer s.sessionsMux.RUnlock()

	session, exists := s.sessions[sessionID]
	return session, exists
}

// UploadChunk チャンクをアップロード（堅牢な並行性制御付き）
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

	// チェックサム検証（早期検証でパフォーマンス向上）
	actualChecksum := utils.CalculateChecksum(chunkData)
	if actualChecksum != expectedChecksum {
		return fmt.Errorf("チェックサム不一致 - 期待値: %s, 実際の値: %s", expectedChecksum, actualChecksum)
	}

	// チャンクレベルのファイルロック取得（10秒タイムアウト）
	chunkLock, err := utils.AcquireChunkLock(sessionID, chunkIndex, 10*time.Second)
	if err != nil {
		return fmt.Errorf("チャンクロック取得エラー: %w", err)
	}
	defer func() {
		if releaseErr := chunkLock.Release(); releaseErr != nil {
			log.Printf("⚠️ [SERVICE] チャンクロック解放エラー (session: %s, chunk: %d): %v", sessionID, chunkIndex, releaseErr)
		}
	}()

	// 重複チェック（ロック内で再確認）
	s.sessionsMux.RLock()
	storedChunk, alreadyUploaded := session.UploadedChunks[chunkIndex]
	sessionStatus := session.Status
	s.sessionsMux.RUnlock()

	if alreadyUploaded {
		// 中身まで同じなら本当に冪等なので、何もせず成功として返す。
		if storedChunk.Checksum == actualChecksum && storedChunk.Size == int64(len(chunkData)) {
			log.Printf("ℹ️ [SERVICE] チャンク %d は既にアップロード済み (session: %s)", chunkIndex, sessionID)
			return fmt.Errorf("チャンク %d は既にアップロード済みです", chunkIndex)
		}

		// 結合フェーズに入ったセッションには書き戻さない。結合が読んでいる最中に
		// 中身を差し替えると、最終ファイルとマニフェストの内容が食い違う。
		// 全チャンクが揃った時点で結合はいつ始まってもおかしくないので、
		// 揃っている状態そのものを受け付けない条件に含める。
		s.sessionsMux.RLock()
		inFinalizePhase := session.IsComplete() ||
			sessionStatus == models.StatusReady ||
			sessionStatus == models.StatusCombining ||
			sessionStatus == models.StatusCompleted
		s.sessionsMux.RUnlock()

		if inFinalizePhase {
			log.Printf("⚠️ [SERVICE] 結合フェーズのセッションへの内容違いの再送を拒否 (session: %s, chunk: %d, status: %s)",
				sessionID, chunkIndex, string(sessionStatus))
			return fmt.Errorf("チャンク %d は既にアップロード済みです", chunkIndex)
		}

		// 中身が違う再送は、保存済みが誤っている可能性があるので新しい内容で置き換える。
		// ここを無条件に「既に受け取った」で捨てると、最初に壊れた内容を保存した時点で
		// 正しい再送も届かなくなり、最終チェックサム検証が恒久的に失敗する。
		log.Printf("⚠️ [SERVICE] チャンク %d の内容が保存済みと異なるため置き換えます (session: %s, 保存済み: %s, 今回: %s)",
			chunkIndex, sessionID, storedChunk.Checksum, actualChecksum)
	}

	// 記録に無いチャンクファイルが残っていても、内容を確かめずに受信済みとして扱わない。
	// 検証済みの今回のデータで原子的に置き換えるほうが、実体と記録が必ず一致する。

	// 原子的なチャンクファイル保存
	chunkFileName := fmt.Sprintf("chunk_%d.dat", chunkIndex)
	chunkFilePath := filepath.Join(session.WorkingDir, chunkFileName)

	if err := utils.AtomicChunkWrite(chunkFilePath, chunkData); err != nil {
		return fmt.Errorf("チャンクファイル保存エラー: %w", err)
	}

	// チャンク情報更新（セッションレベルロック）
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
	uploadedCount := len(session.UploadedChunks)
	totalChunks := session.TotalChunks
	isComplete := session.IsComplete()
	s.sessionsMux.Unlock()

	// 受信済みの記録はチャンク実体と同じくディスクに残す。メモリだけに置くと
	// 再起動でファイルはあるのに未受信扱いになり、全チャンクが再送される。
	// 保存できなかった場合はメモリ側も戻し、クライアントに再送させる。
	// 200 を返してしまうと、クライアントは送り終えたつもりで先に進んでしまう。
	if persistErr := s.persistSession(session); persistErr != nil {
		s.sessionsMux.Lock()
		delete(session.UploadedChunks, chunkIndex)
		session.UpdateStatus()
		s.sessionsMux.Unlock()
		return fmt.Errorf("受信記録の保存に失敗しました: %w", persistErr)
	}

	log.Printf("✅ [SERVICE] Chunk %d uploaded for session %s. Total: %d/%d (%.1f%%)",
		chunkIndex, sessionID, uploadedCount, totalChunks,
		float64(uploadedCount)/float64(totalChunks)*100)

	// 全チャンク到達をサーバ自身が検知して結合を始める。クライアントの
	// POST /complete を待たないので、アプリがバックグラウンドでサスペンドされたままでも
	// ファイルは確定する。POST /complete はその結果を確認するだけの冪等な問い合わせになる。
	if isComplete {
		s.ensureFinalize(sessionID)
	}

	return nil
}

// ensureFinalize セッションの結合を一度だけ開始し、完了を待てるチャネルを返す。
// 既に走っていれば同じチャネルを返すので、最終チャンクの到達と POST /complete が
// 同時に来ても結合は1本しか動かない。
func (s *UploadService) ensureFinalize(sessionID string) chan struct{} {
	s.finalizingMux.Lock()
	defer s.finalizingMux.Unlock()

	if done, exists := s.finalizing[sessionID]; exists {
		return done
	}

	done := make(chan struct{})
	s.finalizing[sessionID] = done
	go s.runFinalize(sessionID, done)
	return done
}

// clearFinalizing 結合中フラグを取り除き、次の呼び出しで結合をやり直せるようにする。
// 成功時は残したままにして、以降の POST /complete が即座に完了を返せるようにする。
func (s *UploadService) clearFinalizing(sessionID string) {
	s.finalizingMux.Lock()
	delete(s.finalizing, sessionID)
	s.finalizingMux.Unlock()
}

// runFinalize チャンク結合と最終チェックサム検証を実行する。
// ロックの外でファイル I/O を行うため、結合中も他セッションの受信と status 取得は止まらない。
func (s *UploadService) runFinalize(sessionID string, done chan struct{}) {
	defer close(done)

	session, exists := s.GetSession(sessionID)
	if !exists {
		s.clearFinalizing(sessionID)
		return
	}

	s.sessionsMux.Lock()
	if session.Status == models.StatusCompleted {
		s.sessionsMux.Unlock()
		return
	}
	if !session.IsComplete() {
		s.sessionsMux.Unlock()
		s.clearFinalizing(sessionID)
		return
	}
	session.Status = models.StatusCombining
	session.FinalizeError = ""
	snapshot := session.Clone()
	s.sessionsMux.Unlock()
	// combining の記録が残らなくても、再起動時に「全チャンク揃い済み」として拾い直せる
	_ = s.persistSession(session)

	log.Printf("🔗 [FINALIZE] session=%s 結合開始 (%d チャンク)", sessionID, snapshot.TotalChunks)

	fatal := false
	finalFilePath, err := utils.CombineChunks(snapshot)
	if err == nil {
		var finalChecksum string
		finalChecksum, err = utils.CalculateFileChecksum(finalFilePath)
		if err == nil && finalChecksum != snapshot.FileChecksum {
			// 同じチャンクから同じ結果しか出ないので、やり直しても変わらない
			err = fmt.Errorf("ファイル整合性チェック失敗 - 期待値: %s, 実際の値: %s", snapshot.FileChecksum, finalChecksum)
			fatal = true
		}
	}

	// 結合中に DELETE されたセッションへ書き戻すと、消したはずの作業ディレクトリが復活する
	if _, stillExists := s.GetSession(sessionID); !stillExists {
		log.Printf("🗑 [FINALIZE] session=%s は結合中に削除されました。結果を破棄します", sessionID)
		return
	}

	if err != nil {
		log.Printf("❌ [FINALIZE] session=%s 結合失敗: %v", sessionID, err)
		s.sessionsMux.Lock()
		session.Status = models.StatusError
		session.FinalizeError = err.Error()
		session.FinalizeFatal = fatal
		session.UpdatedAt = time.Now()
		s.sessionsMux.Unlock()
		_ = s.persistSession(session)

		if fatal {
			// 終端の失敗。フラグを残すことで、以降の complete も起動時の復元も
			// 同じ結合をやり直さず、記録した理由をそのまま返す。
			log.Printf("⛔ [FINALIZE] session=%s は恒久的な失敗として終端にします", sessionID)
			return
		}

		// I/O 由来の一時的な失敗はフラグを外して再試行可能にする。チャンクは残っている。
		s.clearFinalizing(sessionID)
		return
	}

	// 完了を名乗るのは、その記録がディスクに載ってから。順序を逆にすると、
	// GET /status が completed を返した直後に落ちてマニフェストが combining のままになり、
	// クライアントが完了を信じたのにサーバは未完了、という食い違いが起きる。
	// チャンクを消すのも当然この後になる。
	now := time.Now()
	s.sessionsMux.RLock()
	completedSnapshot := session.Clone()
	s.sessionsMux.RUnlock()
	completedSnapshot.Status = models.StatusCompleted
	completedSnapshot.UpdatedAt = now
	completedSnapshot.CompletedAt = &now
	completedSnapshot.FinalFilePath = finalFilePath
	completedSnapshot.FinalizeError = ""

	if err := s.persistSnapshot(completedSnapshot); err != nil {
		log.Printf("❌ [FINALIZE] session=%s 完了記録の保存に失敗。チャンクを残して未完了に戻します: %v", sessionID, err)
		s.sessionsMux.Lock()
		session.Status = models.StatusReady
		session.FinalizeError = err.Error()
		s.sessionsMux.Unlock()
		s.clearFinalizing(sessionID)
		return
	}

	s.sessionsMux.Lock()
	session.Status = models.StatusCompleted
	session.UpdatedAt = now
	session.CompletedAt = &now
	session.FinalFilePath = finalFilePath
	session.FinalizeError = ""
	s.sessionsMux.Unlock()

	// 結合済みなのでチャンク実体は不要。マニフェストの記録は完了の証跡として残す。
	s.cleanupChunkFiles(snapshot)

	log.Printf("✅ [FINALIZE] session=%s 結合完了: %s", sessionID, finalFilePath)
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
		// 再開できる期限をクライアントへ渡す。これを伏せておくと、期限切れの404を
		// 「サーバが壊れた」と誤解して手元のコピーまで捨てる実装になりやすい。
		ExpiresAt:     s.sessionExpiry(session),
		FinalizeError: session.FinalizeError,
		FinalizeFatal: session.FinalizeFatal,
	}, nil
}

// CompleteUpload 結合結果を確認する冪等なAPI。
// 結合そのものは最終チャンク到達時にサーバ側で既に始まっているため、ここでは
// その完了を待つだけになる。何回呼んでも結合は1回しか走らない。
// 待ち時間内に終わらなければ combining のまま返し、クライアントには GET /status を見てもらう。
func (s *UploadService) CompleteUpload(sessionID string) (*models.CompleteResponse, error) {
	session, exists := s.GetSession(sessionID)
	if !exists {
		return nil, fmt.Errorf("セッションが見つかりません: %s", sessionID)
	}

	s.sessionsMux.RLock()
	status := session.Status
	isComplete := session.IsComplete()
	missingChunks := session.GetMissingChunks()
	s.sessionsMux.RUnlock()

	log.Printf("🔍 [SERVICE] CompleteUpload - SessionID: %s, Status: %s, IsComplete: %t", sessionID, string(status), isComplete)

	// 既に完了しているなら結合を起こさずそのまま返す
	if status == models.StatusCompleted {
		return s.buildCompleteResponse(session, "ファイルのアップロードは既に完了しています"), nil
	}

	// 終端の失敗はやり直しても結果が変わらないので、記録した理由をそのまま返す
	s.sessionsMux.RLock()
	fatal := session.FinalizeFatal
	fatalReason := session.FinalizeError
	s.sessionsMux.RUnlock()
	if fatal {
		return nil, errors.New(fatalReason)
	}

	// 全チャンクがアップロード済みかチェック
	if !isComplete {
		log.Printf("❌ [SERVICE] Upload incomplete - missing chunks: %v", missingChunks)
		return nil, fmt.Errorf("アップロードが未完了です。未完了チャンク: %v", missingChunks)
	}

	// 進行中の結合があれば待ち、無ければここで開始する
	select {
	case <-s.ensureFinalize(sessionID):
	case <-time.After(finalizeWaitTimeout):
		log.Printf("⏳ [SERVICE] session=%s 結合待ちがタイムアウト → combining を返します", sessionID)
		return s.buildCompleteResponse(session, "結合処理を実行中です。ステータスを確認してください"), nil
	}

	s.sessionsMux.RLock()
	status = session.Status
	finalizeError := session.FinalizeError
	s.sessionsMux.RUnlock()

	if status != models.StatusCompleted {
		if finalizeError != "" {
			return nil, errors.New(finalizeError)
		}
		return nil, fmt.Errorf("結合処理が完了していません: %s", sessionID)
	}

	return s.buildCompleteResponse(session, "ファイルのアップロードが完了しました"), nil
}

// buildCompleteResponse 完了レスポンスをロック下で組み立てる。
func (s *UploadService) buildCompleteResponse(session *models.UploadSession, message string) *models.CompleteResponse {
	s.sessionsMux.RLock()
	defer s.sessionsMux.RUnlock()

	filePath := session.FinalFilePath
	if filePath == "" {
		filePath = filepath.Join(session.WorkingDir, session.FileName)
	}

	return &models.CompleteResponse{
		SessionID:         session.ID,
		Status:            string(session.Status),
		FinalFileChecksum: session.FileChecksum,
		FilePath:          filePath,
		Message:           message,
	}
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
	s.clearFinalizing(sessionID)
	s.releaseManifestLock(sessionID)

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

// cleanupChunkFiles チャンクファイルを削除（最終ファイルは残す）
func (s *UploadService) cleanupChunkFiles(session *models.UploadSession) {
	for _, chunkInfo := range session.UploadedChunks {
		_ = os.Remove(chunkInfo.FilePath)
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

// CleanupExpiredSessions 期限切れセッションを削除する。
//
// 未完了セッションと完了済みセッションでは消していい理由が違うので、期限を分けて扱う。
// 未完了は「再開されないまま放置された作業領域」なので比較的短く切る。完了済みは
// 結合された成果物そのものなので、同じ期限で消すと「サーバをSoTとして扱う」という
// 前提が短時間で崩れる。クライアントがこの期限を超えて再開しにきた場合は404になるため、
// 再開できる期間は設計上の契約として明示する必要がある。
func (s *UploadService) CleanupExpiredSessions() int {
	s.sessionsMux.Lock()
	defer s.sessionsMux.Unlock()

	now := time.Now()
	expired := make([]string, 0)

	for sessionID, session := range s.sessions {
		maxAge := s.incompleteMaxAge
		if session.Status == models.StatusCompleted {
			maxAge = s.completedMaxAge
		}

		if now.Sub(session.UpdatedAt) > maxAge {
			log.Printf("🗑 [CLEANUP] session=%s status=%s を期限切れとして削除 (経過: %s, 期限: %s)",
				sessionID, string(session.Status), now.Sub(session.UpdatedAt).Round(time.Minute), maxAge)
			_ = utils.CleanupWorkingDirectory(session.WorkingDir)
			delete(s.sessions, sessionID)
			expired = append(expired, sessionID)
		}
	}

	for _, sessionID := range expired {
		s.clearFinalizing(sessionID)
		s.releaseManifestLock(sessionID)
	}

	return len(expired)
}

// sessionExpiry セッションの再開可能期限を返す。クライアントへ提示するために使う。
func (s *UploadService) sessionExpiry(session *models.UploadSession) time.Time {
	if session.Status == models.StatusCompleted {
		return session.UpdatedAt.Add(s.completedMaxAge)
	}
	return session.UpdatedAt.Add(s.incompleteMaxAge)
}
