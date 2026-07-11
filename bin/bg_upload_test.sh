#!/bin/bash
# bg_upload_test.sh
#
# シミュレータ上でアップロード中にアプリを background 遷移させ、
# BackgroundURLSession が upload を継続することを検証する。
#
# ⚠️ 注記: シミュレータでは実 iOS の suspend を完全には再現できない。
# 本テストは "applicationDidEnterBackground" 発火 + delegate 通知継続 の
# 近似検証。真の suspend 越し継続の検証は実機で行う必要がある。
#
# 前提: サーバが http://127.0.0.1:8080 で起動、シミュレータが booted。

set -euo pipefail

SIM_ID="${SIM_ID:-8E924545-616E-4AE4-BACA-CB4663C88DC7}"
BUNDLE="com.okamyuji.fileupload.LargeFileUpload"

# アプリインストール状態を確認
xcrun simctl get_app_container "$SIM_ID" "$BUNDLE" &>/dev/null || {
    echo "[bg_upload_test] アプリが未インストール。先に xcodebuild build → simctl install してください。"
    exit 1
}

# アプリを起動
echo "[bg_upload_test] app launch..."
xcrun simctl launch "$SIM_ID" "$BUNDLE" >/dev/null

sleep 3

# 5 秒間フォアグラウンドで動かした後、Home ボタン相当で background に落とす
echo "[bg_upload_test] sending to background (springboard)..."
xcrun simctl launch "$SIM_ID" com.apple.springboard >/dev/null 2>&1 || true

sleep 5

# BackgroundURLSession の継続を確認するため OS ログを 10 秒 grep
echo "[bg_upload_test] OS log grep (10s)..."
timeout 10 xcrun simctl spawn "$SIM_ID" log stream \
    --predicate "subsystem == 'com.largefileupload'" \
    --style compact 2>&1 | head -30 || true

# 再度フォアグラウンドへ
echo "[bg_upload_test] bring foreground..."
xcrun simctl launch "$SIM_ID" "$BUNDLE" >/dev/null

echo "[bg_upload_test] 完了 (近似検証)"
