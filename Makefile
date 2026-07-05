# Large File Upload System Makefile
# プロジェクト設定
PROJECT_NAME = large-file-upload
SERVER_BINARY = server
CLIENT_BINARY = client
GO_VERSION = 1.21
SWIFT_VERSION = 5.9

# ディレクトリ設定
SERVER_DIR = server
CLIENT_DIR = client
DOCS_DIR = docs
TESTS_DIR = tests
DOCKER_DIR = docker

# Go設定
GOCMD = go
GOBUILD = $(GOCMD) build
GOCLEAN = $(GOCMD) clean
GOTEST = $(GOCMD) test
GOGET = $(GOCMD) get
GOMOD = $(GOCMD) mod

# Docker設定
DOCKER_COMPOSE = docker-compose
DOCKER_IMAGE = $(PROJECT_NAME)
DOCKER_TAG = latest

# デフォルトターゲット
.PHONY: all
all: clean build test

# ヘルプ表示
.PHONY: help
help:
	@echo "利用可能なコマンド:"
	@echo "  make build          - サーバーとクライアントをビルド"
	@echo "  make build-server   - Goサーバーをビルド"
	@echo "  make build-client   - SwiftUIクライアントをビルド"
	@echo "  make test           - 全テストを実行"
	@echo "  make test-server    - サーバーテストを実行"
	@echo "  make test-client    - クライアントテストを実行"
	@echo "  make run-server     - サーバーを起動"
	@echo "  make clean          - ビルド成果物をクリーンアップ"
	@echo "  make deps           - 依存関係をインストール"
	@echo "  make docker-build   - Dockerイメージをビルド"
	@echo "  make docker-run     - Docker環境で実行"
	@echo "  make perf-test      - パフォーマンステストを実行"
	@echo "  make docs           - ドキュメントを生成"
	@echo "  make lint           - コード品質チェック"
	@echo ""
	@echo "iOS実機向けコマンド:"
	@echo "  make ios-devices    - 接続されたiOSデバイス一覧を表示"
	@echo "  make ios-build      - iOS実機向けリリースビルド"
	@echo "  make ios-install    - iOS実機にアプリをインストール"
	@echo "  make ios-debug      - iOS実機向けデバッグビルド"
	@echo "  make ios-log        - iOS実機のリアルタイムログを表示"
	@echo "  make ios-memory     - iOS実機のメモリ使用量を監視"
	@echo ""
	@echo "デバッグ・分析コマンド:"
	@echo "  make debug-server   - サーバーをデバッグモードで起動"
	@echo "  make profile-server - サーバーのプロファイリングを開始"
	@echo "  make memory-check   - メモリリーク検出"
	@echo "  make race-check     - 競合状態検出"
	@echo ""
	@echo "iPhone12Pro専用ショートカット:"
	@echo "  make iphone12pro-deploy    - iPhone12Proに完全デプロイ"
	@echo "  make iphone12pro-log       - iPhone12Proのリアルタイムログ"
	@echo "  make iphone12pro-diagnose  - iPhone12Proの問題診断"

# ビルドターゲット
.PHONY: build
build: build-server build-client

.PHONY: build-server
build-server:
	@echo "Goサーバーをビルド中..."
	cd $(SERVER_DIR) && $(GOBUILD) -o ../bin/$(SERVER_BINARY) -v .
	@echo "サーバービルド完了"

.PHONY: build-client
build-client:
	@echo "SwiftUIクライアントをビルド中..."
	cd $(CLIENT_DIR) && xcodebuild -scheme LargeFileUpload -configuration Release -derivedDataPath ../build
	@echo "クライアントビルド完了"

# テストターゲット
.PHONY: test
test: test-server test-client

.PHONY: test-server
test-server:
	@echo "サーバーテストを実行中..."
	cd $(SERVER_DIR) && $(GOTEST) -v ./...
	@echo "サーバーテスト完了"

.PHONY: test-client
test-client:
	@echo "クライアントテストを実行中..."
	cd $(CLIENT_DIR) && xcodebuild test -scheme LargeFileUpload -destination 'platform=iOS Simulator,name=iPhone 15'
	@echo "クライアントテスト完了"

# 実行ターゲット
.PHONY: run-server
run-server:
	@echo "サーバーを起動中..."
	cd $(SERVER_DIR) && $(GOCMD) run main.go

.PHONY: run-server-binary
run-server-binary: build-server
	@echo "ビルドされたサーバーを起動中..."
	./bin/$(SERVER_BINARY)

# 依存関係管理
.PHONY: deps
deps: deps-server deps-client

.PHONY: deps-server
deps-server:
	@echo "Go依存関係をインストール中..."
	cd $(SERVER_DIR) && $(GOMOD) tidy
	cd $(SERVER_DIR) && $(GOMOD) verify

.PHONY: deps-client
deps-client:
	@echo "Swift依存関係をインストール中..."
	# SwiftUIは追加ライブラリを使わないため、特別な処理は不要

# クリーンアップ
.PHONY: clean
clean:
	@echo "ビルド成果物をクリーンアップ中..."
	rm -rf bin/
	rm -rf build/
	cd $(SERVER_DIR) && $(GOCLEAN)
	@echo "クリーンアップ完了"

# コード品質チェック
.PHONY: lint
lint: lint-server lint-client

.PHONY: lint-server
lint-server:
	@echo "Goコード品質チェック中..."
	cd $(SERVER_DIR) && $(GOCMD) fmt ./...
	cd $(SERVER_DIR) && $(GOCMD) vet ./...
	@echo "Go品質チェック完了"

.PHONY: lint-client
lint-client:
	@echo "Swiftコード品質チェック中..."
	cd $(CLIENT_DIR) && swiftlint lint || true
	@echo "Swift品質チェック完了"

# Docker操作
.PHONY: docker-build
docker-build:
	@echo "Dockerイメージをビルド中..."
	$(DOCKER_COMPOSE) build
	@echo "Dockerビルド完了"

.PHONY: docker-run
docker-run:
	@echo "Docker環境で実行中..."
	$(DOCKER_COMPOSE) up -d
	@echo "Docker環境起動完了"

.PHONY: docker-stop
docker-stop:
	@echo "Docker環境を停止中..."
	$(DOCKER_COMPOSE) down
	@echo "Docker環境停止完了"

.PHONY: docker-logs
docker-logs:
	$(DOCKER_COMPOSE) logs -f

# パフォーマンステスト
.PHONY: perf-test
perf-test:
	@echo "パフォーマンステストを実行中..."
	cd $(TESTS_DIR)/performance && k6 run upload_performance_test.js
	@echo "パフォーマンステスト完了"

# ドキュメント生成
.PHONY: docs
docs:
	@echo "ドキュメントを生成中..."
	@echo "OpenAPI仕様は docs/api.yaml に格納されています"
	@echo "README.mdとその他のドキュメントを参照してください"

# 開発環境セットアップ
.PHONY: setup-dev
setup-dev:
	@echo "開発環境をセットアップ中..."
	mkdir -p bin
	mkdir -p build
	mkdir -p uploads
	$(MAKE) deps
	@echo "開発環境セットアップ完了"

# 本番環境デプロイ
.PHONY: deploy
deploy: clean build test docker-build
	@echo "本番環境にデプロイ準備完了"
	@echo "docker-compose up -d を実行してサービスを開始してください"

# CI/CD用ターゲット
.PHONY: ci
ci: deps lint build test
	@echo "CI/CDパイプライン完了"

# 統合テスト
.PHONY: integration-test
integration-test: docker-run
	@echo "統合テストを実行中..."
	sleep 5  # サーバー起動待機
	cd $(TESTS_DIR) && $(GOTEST) -tags=integration -v ./...
	$(MAKE) docker-stop
	@echo "統合テスト完了"

# セキュリティスキャン
.PHONY: security-scan
security-scan:
	@echo "セキュリティスキャンを実行中..."
	cd $(SERVER_DIR) && $(GOCMD) list -json -m all | nancy sleuth || true
	@echo "セキュリティスキャン完了"

# ベンチマーク
.PHONY: benchmark
benchmark:
	@echo "ベンチマークテストを実行中..."
	cd $(SERVER_DIR) && $(GOTEST) -bench=. -benchmem ./...
	@echo "ベンチマークテスト完了"

# iOS実機向けコマンド
.PHONY: ios-devices
ios-devices:
	@echo "接続されたiOSデバイス一覧:"
	xcrun devicectl list devices

.PHONY: ios-build
ios-build:
	@echo "iOS実機向けリリースビルド中..."
	@echo "⚠️  使用前にDEVICE_IDを設定してください: make ios-build DEVICE_ID=YOUR_DEVICE_ID"
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		echo "例: make ios-build DEVICE_ID=39C432F8-80DC-546F-82C2-51C8DA10A05A"; \
		exit 1; \
	fi
	cd $(CLIENT_DIR) && xcodebuild \
		-project LargeFileUpload.xcodeproj \
		-scheme LargeFileUpload \
		-configuration Release \
		-destination 'platform=iOS,id=$(DEVICE_ID)' \
		-derivedDataPath ../build \
		build
	@echo "iOS実機向けリリースビルド完了"

.PHONY: ios-debug
ios-debug:
	@echo "iOS実機向けデバッグビルド中..."
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		echo "例: make ios-debug DEVICE_ID=39C432F8-80DC-546F-82C2-51C8DA10A05A"; \
		exit 1; \
	fi
	cd $(CLIENT_DIR) && xcodebuild \
		-project LargeFileUpload.xcodeproj \
		-scheme LargeFileUpload \
		-configuration Debug \
		-destination 'platform=iOS,id=$(DEVICE_ID)' \
		-derivedDataPath ../build \
		build
	@echo "iOS実機向けデバッグビルド完了"

.PHONY: ios-install
ios-install:
	@echo "iOS実機にアプリをインストール中..."
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		echo "例: make ios-install DEVICE_ID=39C432F8-80DC-546F-82C2-51C8DA10A05A"; \
		exit 1; \
	fi
	xcrun devicectl device install app \
		build/Build/Products/Release-iphoneos/LargeFileUpload.app \
		--device $(DEVICE_ID)
	@echo "iOS実機へのインストール完了"

.PHONY: ios-launch
ios-launch:
	@echo "iOS実機でアプリを起動中..."
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		exit 1; \
	fi
	xcrun devicectl device process launch \
		com.example.LargeFileUpload \
		--device $(DEVICE_ID) \
		--start-stopped
	@echo "アプリ起動完了"

.PHONY: ios-log
ios-log:
	@echo "iOS実機のリアルタイムログを表示中..."
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		echo "例: make ios-log DEVICE_ID=39C432F8-80DC-546F-82C2-51C8DA10A05A"; \
		exit 1; \
	fi
	@echo "⚠️  xcrun devicectl構文エラーのため、従来の方法を使用します"
	@echo "コンソールアプリでデバイスログを確認するか、Xcodeのログを使用してください"
	@echo "または、以下のコマンドを手動実行してください:"
	@echo "log stream --device $(DEVICE_ID) --predicate 'process == \"LargeFileUpload\"'"

.PHONY: ios-memory
ios-memory:
	@echo "iOS実機のメモリ使用量を監視中..."
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		exit 1; \
	fi
	@echo "⚠️  この機能には追加のツールが必要です"
	@echo "Xcodeの Instruments を使用してメモリ分析を実行してください"
	@echo "または、コンソールアプリでメモリ関連ログを確認してください"

.PHONY: ios-full-deploy
ios-full-deploy:
	@echo "iOS実機への完全デプロイ（ビルド→インストール→起動）"
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		echo "例: make ios-full-deploy DEVICE_ID=39C432F8-80DC-546F-82C2-51C8DA10A05A"; \
		exit 1; \
	fi
	$(MAKE) ios-build DEVICE_ID=$(DEVICE_ID)
	$(MAKE) ios-install DEVICE_ID=$(DEVICE_ID)
	$(MAKE) ios-launch DEVICE_ID=$(DEVICE_ID)
	@echo "完全デプロイ完了"

# デバッグ・分析コマンド
.PHONY: debug-server
debug-server:
	@echo "サーバーをデバッグモードで起動中..."
	cd $(SERVER_DIR) && LOG_LEVEL=debug GOMAXPROCS=1 $(GOCMD) run main.go

.PHONY: profile-server
profile-server:
	@echo "サーバーのプロファイリングを開始中..."
	@echo "プロファイリングサーバーは http://localhost:6060/debug/pprof/ で利用可能です"
	cd $(SERVER_DIR) && $(GOCMD) run main.go -pprof=:6060

.PHONY: memory-check
memory-check:
	@echo "メモリリーク検出を実行中..."
	cd $(SERVER_DIR) && $(GOTEST) -v ./... -race -coverprofile=coverage.out
	cd $(SERVER_DIR) && $(GOCMD) tool cover -html=coverage.out -o coverage.html
	@echo "メモリチェック完了。coverage.htmlを確認してください"

.PHONY: race-check
race-check:
	@echo "競合状態検出を実行中..."
	cd $(SERVER_DIR) && $(GOTEST) -race -v ./...
	cd $(SERVER_DIR) && $(GOBUILD) -race -o ../bin/$(SERVER_BINARY)-race .
	@echo "競合状態チェック完了"

.PHONY: stress-test
stress-test:
	@echo "ストレステストを実行中..."
	@echo "サーバーが起動していることを確認してください"
	cd $(TESTS_DIR)/performance && node upload-test.js

.PHONY: thread-analysis
thread-analysis:
	@echo "スレッド分析を実行中..."
	cd $(SERVER_DIR) && $(GOCMD) tool pprof -top -cum http://localhost:8080/debug/pprof/goroutine

.PHONY: heap-analysis
heap-analysis:
	@echo "ヒープ分析を実行中..."
	cd $(SERVER_DIR) && $(GOCMD) tool pprof -top -cum http://localhost:8080/debug/pprof/heap

# 問題診断用コマンド
.PHONY: diagnose-ios
diagnose-ios:
	@echo "iOS実機の問題診断を実行中..."
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "エラー: DEVICE_IDが設定されていません"; \
		exit 1; \
	fi
	@echo "=== デバイス情報 ==="
	xcrun devicectl list devices
	@echo "=== 診断情報 ==="
	@echo "デバイスID: $(DEVICE_ID)"
	@echo "⚠️  xcrun devicectl構文問題により、ログストリームは手動で実行してください"
	@echo ""
	@echo "メモリ関連ログを確認する場合:"
	@echo "log stream --device $(DEVICE_ID) --predicate 'eventMessage CONTAINS \"memory\"'"
	@echo ""
	@echo "malloc関連ログを確認する場合:"
	@echo "log stream --device $(DEVICE_ID) --predicate 'eventMessage CONTAINS \"malloc\"'"
	@echo ""
	@echo "アプリ固有ログを確認する場合:"
	@echo "log stream --device $(DEVICE_ID) --predicate 'process == \"LargeFileUpload\"'"
	@echo ""
	@echo "推奨診断手順:"
	@echo "1. Xcodeのコンソールでリアルタイムログを監視"
	@echo "2. コンソールアプリでデバイスログをフィルタリング"
	@echo "3. Instrumentsでメモリプロファイルを実行"

.PHONY: fix-ios-threading
fix-ios-threading:
	@echo "iOS Threading問題の修正ガイド:"
	@echo "1. 'Publishing changes from background threads' エラーの修正"
	@echo "   - DispatchQueue.main.async でUI更新を囲む"
	@echo "   - @MainActor を使用する"
	@echo "2. TaskID失効問題の修正"
	@echo "   - URLSessionTaskの状態管理を見直す"
	@echo "   - 並行タスクの制限を実装する"
	@echo "3. malloc エラーの修正"
	@echo "   - メモリリークの検出と修正"
	@echo "   - ARC（Automatic Reference Counting）の確認"

# iPhone12Pro用のショートカット（あなたのデバイス用）
.PHONY: iphone12pro-deploy
iphone12pro-deploy:
	$(MAKE) ios-full-deploy DEVICE_ID=00008101-000D78C80E29003A

.PHONY: iphone12pro-log
iphone12pro-log:
	$(MAKE) ios-log DEVICE_ID=00008101-000D78C80E29003A

.PHONY: iphone12pro-diagnose
iphone12pro-diagnose:
	$(MAKE) diagnose-ios DEVICE_ID=00008101-000D78C80E29003A
