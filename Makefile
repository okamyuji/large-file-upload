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
