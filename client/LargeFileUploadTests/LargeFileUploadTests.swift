//
//  LargeFileUploadTests.swift
//  LargeFileUploadTests
//
//  Created by Yuji OKAMOTO on 2025/07/06.
//

import Testing

@testable import LargeFileUpload

struct LargeFileUploadTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

/// UploadManager.shared / NetworkService.shared / upload_state.json という
/// プロセス共有状態に触るスイートの親コンテナ。
///
/// Swift Testing は「スイート内」は .serialized で直列化できるが、
/// スイート同士は並列実行される。共有シングルトンを触るスイートが並走すると
/// activeUploads に他スイートのセッションが混入する等の相互汚染で flaky になる
/// (2026-07-12 に全 suite 実行で 7 件の再現を確認)。
/// .serialized はネストしたスイートへ再帰適用されるため、この配下に入れた
/// スイートは横断的に 1 本ずつ実行される。
/// 共有シングルトンや永続化ファイルに触るテストスイートは必ずこの extension
/// 配下に宣言すること。
@Suite(.serialized)
enum SerializedSingletonTests {}
