import Foundation
import os

/// アプリ全体で共有する os.Logger サブシステム。
/// 使い方: `AppLog.upload.info("...")` のように呼ぶ。
enum AppLog {
    private static let subsystem = "com.largefileupload"

    static let upload  = Logger(subsystem: subsystem, category: "upload")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let retry   = Logger(subsystem: subsystem, category: "retry")
    static let bg      = Logger(subsystem: subsystem, category: "background")
    static let file    = Logger(subsystem: subsystem, category: "file")
}
