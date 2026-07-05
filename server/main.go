package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"large-file-upload-server/handlers"
	"large-file-upload-server/services"
	"large-file-upload-server/utils"
)

const (
	DefaultPort            = "8080"
	ReadTimeout            = 60 * time.Second  // 大容量チャンクアップロード用に延長
	WriteTimeout           = 60 * time.Second  // レスポンス送信用に延長
	IdleTimeout            = 120 * time.Second // 接続維持時間を延長
	SessionCleanupInterval = 1 * time.Hour
	SessionMaxAge          = 24 * time.Hour
)

func main() {
	// uploadsディレクトリを確保
	if err := utils.EnsureUploadsDirectory(); err != nil {
		log.Fatalf("uploadsディレクトリ作成エラー: %v", err)
	}

	// サービス初期化
	uploadService := services.NewUploadService()

	// ハンドラー初期化
	uploadHandler := handlers.NewUploadHandler(uploadService)

	// ルーター設定
	mux := http.NewServeMux()

	// アップロード関連のエンドポイント
	mux.Handle("/upload/", uploadHandler)

	// ヘルスチェックエンドポイント
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		utils.EnableCORS(w, r)
		if r.Method == "OPTIONS" {
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"healthy","timestamp":"` + time.Now().Format(time.RFC3339) + `"}`))
	})

	// ルートパス
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		utils.EnableCORS(w, r)
		if r.Method == "OPTIONS" {
			return
		}

		if r.URL.Path != "/" {
			utils.WriteErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "エンドポイントが見つかりません")
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"message":"大容量ファイル分割アップロードAPI","version":"1.0.0"}`))
	})

	// ポート設定
	port := os.Getenv("PORT")
	if port == "" {
		port = DefaultPort
	}

	// サーバー設定
	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  ReadTimeout,
		WriteTimeout: WriteTimeout,
		IdleTimeout:  IdleTimeout,
	}

	// セッションクリーンアップのゴルーチン開始
	go startSessionCleanup(uploadService)

	// グレースフルシャットダウンの設定
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		log.Println("シャットダウンシグナルを受信しました...")

		// 5秒のタイムアウトでシャットダウン
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		if err := server.Shutdown(ctx); err != nil {
			log.Printf("サーバーシャットダウンエラー: %v", err)
		}
	}()

	// サーバー開始
	log.Printf("サーバーを開始します（ポート: %s）", port)
	log.Printf("API仕様書: http://localhost:%s/", port)
	log.Printf("ヘルスチェック: http://localhost:%s/health", port)

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("サーバー開始エラー: %v", err)
	}

	log.Println("サーバーが正常に停止しました")
}

// startSessionCleanup 定期的にセッションクリーンアップを実行
func startSessionCleanup(uploadService *services.UploadService) {
	ticker := time.NewTicker(SessionCleanupInterval)
	defer ticker.Stop()

	for range ticker.C {
		deletedCount := uploadService.CleanupExpiredSessions(SessionMaxAge)
		if deletedCount > 0 {
			log.Printf("期限切れセッション %d 個を削除しました", deletedCount)
		}
	}
}
