# 大容量ファイルアップロードシステム

チャンク分割ファイルアップロードシステムです。Goサーバー（標準net/httpのみ）とSwiftUIクライアント（追加ライブラリなし）で実装されており、ファイルロック・原子的操作による競合状態対策、バックグラウンド送信、チェックサム検証、セッション管理機能を備えています。iPhone実機で1GBファイルのアップロード完走を検証済みです。

## 主要機能

### アップロード方式

- チャンク分割アップロード: ファイルサイズに応じて1MB〜10MBのチャンクへ適応分割（総チャンク数200以下）
- 全チャンク一括投入: 開始・再開時に残りチャンクのPUTタスクをすべてBackgroundURLSessionへ投入し、httpMaximumConnectionsPerHost=1で逐次配送
- SHA256チェックサム: チャンク単位とファイル全体の整合性検証
- セッション管理: 中断・再開可能なアップロード処理（サーバのmissingChunksをSoTとして再開）

### iOS対応

- バックグラウンド送信: 投入済みタスクをnsurlsessiondが所有するため、アプリのサスペンド中も送信が継続
- ネイティブリトライ: Task.sleepを使わず、earliestBeginDateによるOS所有のリトライスケジューリング（指数バックオフ+Retry-After尊重）
- 画面ロック対応: 自動スリープ時の送信継続
- SwiftUI純正実装: 追加ライブラリ不使用

### 堅牢性

- ファイルロック機能: チャンクレベルの排他制御（syscall.Flock）
- 原子的操作: 一時ファイル方式による安全なファイル書き込み
- 冪等性保証: 重複チャンクは200 OK（already_uploaded）で処理
- エラー分類: RetryClassifierによる恒久エラー・過負荷・一時エラーの振り分け
- 状態永続化: happy-pathでもupload_state.jsonへ保存し、Force Quit後も復元
- テスト: ユニット・実サーバ統合・fault-injectionテスト

## プロジェクト構造

```text
large-file-upload/
├── server/                 # Goサーバー実装
│   ├── main.go            # メインサーバーファイル
│   ├── main_test.go       # メインテストファイル
│   ├── go.mod             # Go依存関係管理
│   ├── Dockerfile         # サーバー用Dockerfile
│   ├── models/            # データ構造定義
│   │   └── models.go
│   ├── services/          # ビジネスロジック
│   │   └── upload_service.go
│   ├── handlers/          # HTTPハンドラー
│   │   └── upload_handler.go
│   ├── middleware/        # fault-injection等のミドルウェア
│   │   └── fault_injection.go
│   ├── utils/             # ユーティリティ関数
│   │   └── utils.go
│   └── uploads/           # アップロード作業ディレクトリ
├── client/                # SwiftUIクライアント実装
│   ├── LargeFileUpload.xcodeproj/ # Xcodeプロジェクト
│   ├── LargeFileUpload/   # アプリケーション本体
│   │   ├── LargeFileUploadApp.swift    # アプリエントリーポイント
│   │   ├── ContentView.swift           # メインビュー
│   │   ├── ActiveUploadsView.swift     # アクティブアップロード画面
│   │   ├── HistoryAndSettingsView.swift # 履歴・設定画面
│   │   ├── Models.swift                # データモデル
│   │   ├── NetworkService.swift        # ネットワークサービス
│   │   ├── NetworkMonitor.swift        # ネットワーク監視
│   │   ├── UploadManager.swift         # アップロード管理
│   │   ├── FileManager.swift           # ファイル管理
│   │   ├── RetryPolicy.swift           # リトライ間隔ポリシー
│   │   ├── RetryDecision.swift         # エラー分類（RetryClassifier）
│   │   ├── AppLogger.swift             # os.Loggerラッパー
│   │   ├── AppDelegate.swift           # アプリデリゲート
│   │   ├── Info.plist                  # アプリ設定
│   │   └── Assets.xcassets/            # アセット
│   ├── LargeFileUploadTests/      # ユニット・統合テスト
│   └── LargeFileUploadUITests/    # UIテスト
│       ├── LargeFileUploadUITests.swift
│       └── LargeFileUploadUITestsLaunchTests.swift
├── docs/                  # ドキュメント
│   └── openapi.yaml      # OpenAPI 3.1仕様
├── tests/                 # パフォーマンステスト
│   └── performance/
│       └── upload-test.js
├── bin/                   # テストスクリプト（bg_upload_test.sh）
├── build/                 # Xcodeビルドキャッシュ
├── uploads/               # サーバーアップロード保存先
├── .github/               # CI/CD設定
│   └── workflows/
│       └── ci-cd.yml
├── compose.yml            # Docker Compose設定
├── Makefile               # ビルド・テスト自動化
└── README.md              # 本ファイル
```

## 技術仕様

### サーバー側（Go）

- **言語**: Go 1.21+
- **フレームワーク**: 標準net/httpライブラリのみ
- **ハッシュ**: SHA256チェックサム
- **ストレージ**: ローカルファイルシステム
- **並行性制御**: チャンクレベルファイルロック（syscall.Flock）
- **原子的操作**: 一時ファイル方式による安全な書き込み
- **冪等性**: 重複チャンクの適切な処理
- **タイムアウト**: 大容量ファイル用最適化（ReadTimeout: 60s, WriteTimeout: 60s）
- **設定**: 環境変数による設定管理

### クライアント側（Swift）

- **言語**: Swift 5.9+
- **フレームワーク**: SwiftUI（追加ライブラリなし）
- **バックグラウンド**: URLSessionConfiguration.background（全チャンク一括投入、httpMaximumConnectionsPerHost=1で逐次配送）
- **リトライ**: URLSessionTask.earliestBeginDateによるOS所有スケジューリング
- **対応OS**: iOS 18.5+

### API仕様

- **プロトコル**: HTTP/1.1, HTTP/2
- **認証**: なし（検証用実装。本番環境ではJWT等の追加が必要）
- **フォーマット**: OpenAPI 3.1準拠
- **エンドポイント**: RESTful API設計

## クイックスタート

### 前提条件

- Go 1.21以上
- Xcode 15以上（Swift 5.9+）
- Docker（オプション）
- Make（ビルド自動化）

### 1. リポジトリクローン・セットアップ

```bash
# 既にディレクトリが存在する場合
cd large-file-upload

# 開発環境セットアップ
make setup-dev
```

### 2. サーバー起動

```bash
# 開発モードで起動
make run-server

# または本番ビルド後起動
make build-server
./bin/server
```

### 3. クライアント起動

```bash
# シミュレーター実行（例：iPhone 16 Pro/iOS 18.2）
# Debugビルド
cd client && xcodebuild -scheme LargeFileUpload -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' build

# Releaseビルド
cd client && xcodebuild -scheme LargeFileUpload -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2' -configuration Release build

# Releaseアプリをシミュレーターで起動
cd client && xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/LargeFileUpload-*/Build/Products/Release-iphonesimulator/LargeFileUpload.app && xcrun simctl launch booted com.okamyuji.fileupload.LargeFileUpload

# 実機実行
# 接続された実機一覧確認
xcrun devicectl list devices

# 実機でビルド（UDIDを指定）
cd client && xcodebuild -scheme LargeFileUpload -destination 'platform=iOS,id=YOUR_DEVICE_UDID' build

# 実機にインストール（要Developer Certificate）
cd client && xcodebuild -scheme LargeFileUpload -destination 'platform=iOS,id=YOUR_DEVICE_UDID' -configuration Release install

# Xcode GUI
open client/LargeFileUpload.xcodeproj
```

### 4. Dockerでの起動（推奨）

```bash
# 開発環境（Docker Compose使用）
docker-compose -f compose.yml up -d

# または Makefileを使用
make docker-run

# コンテナ停止
docker-compose -f compose.yml down
```

## 開発・テスト

### ビルドとテスト

```bash
# 全体ビルド
make build

# テスト実行
make test

# パフォーマンステスト
make perf-test

# コード品質チェック
make lint

# 統合テスト
make integration-test
```

### 開発ワークフロー

```bash
# 1. コード変更後の基本チェック
make ci

# 2. パフォーマンス確認
make benchmark

# 3. セキュリティスキャン
make security-scan

# 4. デプロイ準備
make deploy
```

## API使用例

### セッション作成

```bash
curl -X POST http://localhost:8080/upload/session \
  -H "Content-Type: application/json" \
  -d '{
    "fileName": "large_file.zip",
    "fileSize": 1073741824,
    "chunkSize": 1048576,
    "totalChunks": 1024,
    "fileChecksum": "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3"
  }'
```

### チャンクアップロード

```bash
# バイナリチャンクファイルをアップロード
curl -X PUT http://localhost:8080/upload/session/session_1234567890_abcdef/chunk/0 \
  -H "Content-Type: application/octet-stream" \
  -H "X-Chunk-Checksum: b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78" \
  --data-binary @chunk_000.bin
```

### セッションステータス確認

```bash
curl -X GET http://localhost:8080/upload/session/session_1234567890_abcdef/status
```

### アップロード完了

```bash
curl -X POST http://localhost:8080/upload/session/session_1234567890_abcdef/complete
```

### セッション削除

```bash
curl -X DELETE http://localhost:8080/upload/session/session_1234567890_abcdef
```

## 設定

### 環境変数

```bash
# サーバー設定
export PORT=8080  # 待ち受けポート（未設定時は8080）

# fault-injectionテスト用（本番では設定しない）
export LARGE_FILE_UPLOAD_FAULT_RATE=0.15  # チャンクPUTを指定確率で503にする
export LARGE_FILE_UPLOAD_FAULT_SEED=42    # 乱数シード（再現用、省略可）
```

チャンクサイズの上限（10MB）・下限（1KB）とセッション検証はサーバコード内で固定です。

### iOS設定

`client/LargeFileUpload/Info.plist`で以下を設定します。

   ```xml
   <!-- 接続先サーバ（環境変数 LARGE_FILE_UPLOAD_SERVER でも上書き可能） -->
   <key>LARGE_FILE_UPLOAD_SERVER</key>
   <string>http://192.168.x.x:8080</string>
   <key>NSAppTransportSecurity</key>
   <dict>
      <key>NSAllowsArbitraryLoads</key>
      <true/>
   </dict>
   <key>UIBackgroundModes</key>
   <array>
      <string>background-fetch</string>
      <string>background-processing</string>
      <string>background-upload</string>
   </array>
   ```

## パフォーマンス特性

iPhone 12 Pro実機とローカルMacサーバでの実測値です（2026-07）。

- 1GBファイル単発: USB tunnel経由で約50秒（チャンク128個）
- 200MB×3回連続: 約75秒
- 906MBファイル: Wi-Fi（IPv6）経由、バックグラウンド移行を挟んで約2分で完走
- fault-injection（503を15%注入）下の200MB: リトライ経由で約43秒

チャンクサイズはファイルサイズから適応的に決まり（1MB〜10MB、総チャンク数200以下）、サーバはチャンクサイズ1KB〜10MBの範囲外を拒否します。

スケール構成（オブジェクトストレージ直接PUT、Redis/DBでのセッション管理、非同期結合など）はこのリポジトリの範囲外です。設計指針は[解説記事](https://zenn.dev/okamyuji)を参照してください。

## セキュリティ考慮事項

### 実装済み対策

- **チェックサム検証**: SHA256による完全性保証
- **ファイルロック**: OSレベルの排他制御（syscall.Flock）
- **原子的操作**: 中断安全なファイル書き込み
- **冪等性保証**: 重複リクエストの安全な処理
- **チャンクサイズ制限**: 1KB〜10MBの範囲外を拒否
- **ロック競合時の429**: Retry-Afterヘッダ付きで再試行を誘導
- **入力値検証**: セッション作成・チャンク受信パラメータの検証
- **パス操作対策**: 一時ファイル名はセッションIDと連番のみで構成

### 本番環境推奨設定

- **HTTPS必須**: TLS 1.3以上
- **認証**: JWT + OAuth2
- **ファイアウォール**: 必要ポートのみ開放
- **ログ監視**: セキュリティイベント記録

## トラブルシューティング

### よくある問題

#### 1. 409エラー（重複チャンクアップロード）- 解決済み

   **症状**: 同時並列アップロードで409 Conflict エラーが発生

   **原因**: 従来の実装では競合状態（Race Condition）が発生していました

   **解決策**:
   - チャンクレベルのファイルロック（syscall.Flock）実装済み
   - 原子的ファイル操作による安全な書き込み
   - 重複チャンクは200 OKで成功として処理（冪等性保証）

   ```bash
   # システムが正常に動作していることを確認
   curl -X GET http://localhost:8080/health
   ```

#### 2. 429エラー（チャンクロック取得失敗）

   **症状**: "CHUNK_LOCK_FAILED" エラーで429 Too Many Requests
   
   **対策**: 
   ```bash
   # 少し待ってからリトライ（推奨間隔：1-3秒）
   sleep 2 && curl -X PUT "http://localhost:8080/upload/session/{sessionId}/chunk/{chunkIndex}" \
     -H "Content-Type: application/octet-stream" \
     -H "X-Chunk-Checksum: {checksum}" \
     --data-binary @chunk.bin
   ```

#### 3. バックグラウンド送信が停止する

   **症状**: アプリをバックグラウンドにするとチャンク到達が止まり、フォアグラウンド復帰と同時に再開する

   **原因**: BackgroundURLSessionが送り続けるのは投入済みタスクだけです。チャンク完了のデリゲートで次の1個を投入する逐次方式だと、サスペンド中は次を積む主体が不在になり送信が止まります

   **解決策**: 開始・再開時に残りチャンクのタスクをすべて投入します（本リポジトリではenqueueAllPendingChunksとして実装済み）。切り分けにはサーバ側アクセスログのタイムスタンプを時系列で確認するのが確実です

   ```bash
   # iOSシミュレータでのクライアントログ確認
   xcrun simctl spawn booted log show --predicate 'process == "LargeFileUpload"'
   ```

#### 4. チェックサムエラー

   ```bash
   # サーバーログ確認
   docker logs large-file-upload_server_1

   # ファイル整合性確認
   shasum -a 256 uploaded_file.bin
   ```

#### 5. パフォーマンス低下

   ```bash
   # サーバーメトリクス確認
   make benchmark

   # プロファイリング実行
   go tool pprof http://localhost:8080/debug/pprof/profile
   ```

#### 6. タイムアウトエラー

   **症状**: 大容量チャンクアップロード時のタイムアウト

   **設定確認**: サーバはReadTimeout 60秒、WriteTimeout 60秒で構成されています。クライアント側はチャンク単体300秒、リソース全体7日で構成されています（server/main.go、NetworkService.swiftを参照）

### ログ確認

   ```bash
   # サーバーログ
   make docker-logs

   # クライアントログ（Xcode Console）
   # Devices and Simulators > デバイス選択 > Open Console
   ```

## 貢献ガイドライン

### 開発フロー

1. フィーチャーブランチ作成
2. 実装・テスト
3. `make ci`でCI確認
4. プルリクエスト作成
5. コードレビュー
6. マージ

### コードスタイル

- **Go**: `gofmt`, `go vet`準拠
- **Swift**: Swift標準スタイルガイド準拠
- **コメント**: 日本語・英語併記
- **テスト**: 新機能には必須

## ライセンス

MIT License - 詳細は`LICENSE`ファイルを参照

## 作者・連絡先

プロジェクト管理者: okamyuji
技術的質問: GitHub Issues

---
