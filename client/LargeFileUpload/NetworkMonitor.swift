import Combine
import Foundation
import Network

/// ネットワーク接続状態を監視するクラス
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    // MARK: - Published Properties

    @Published var isConnected: Bool = false
    @Published var connectionType: ConnectionType = .unknown
    @Published var isExpensive: Bool = false
    @Published var isConstrained: Bool = false

    // MARK: - Types

    enum ConnectionType {
        case unknown
        case wifi
        case cellular
        case ethernet
        case other

        var displayName: String {
            switch self {
            case .unknown:
                return "不明"
            case .wifi:
                return "Wi-Fi"
            case .cellular:
                return "モバイル"
            case .ethernet:
                return "有線"
            case .other:
                return "その他"
            }
        }

        var isReliable: Bool {
            switch self {
            case .wifi, .ethernet:
                return true
            case .cellular, .other, .unknown:
                return false
            }
        }
    }

    // MARK: - Private Properties

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor", qos: .background)
    private var cancellables = Set<AnyCancellable>()
    
    // 📋 ネットワーク変更時のコールバック
    private var networkChangeCallbacks: [(ConnectionType, ConnectionType) -> Void] = []
    private var connectionRecoveryCallbacks: [() -> Void] = []

    // MARK: - Initialization

    private init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// ネットワーク監視を開始
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateNetworkStatus(path: path)
            }
        }
        monitor.start(queue: queue)

        print("ネットワーク監視を開始しました")
    }

    /// ネットワーク監視を停止
    func stopMonitoring() {
        monitor.cancel()
        print("ネットワーク監視を停止しました")
    }
    
    // MARK: - Callback Management
    
    /// ネットワーク変更時のコールバックを登録
    func onNetworkChange(callback: @escaping (ConnectionType, ConnectionType) -> Void) {
        networkChangeCallbacks.append(callback)
    }
    
    /// 接続復旧時のコールバックを登録
    func onConnectionRecovery(callback: @escaping () -> Void) {
        connectionRecoveryCallbacks.append(callback)
    }

    /// アップロードに適した接続状態かどうかを判定
    var isOptimalForUpload: Bool {
        return isConnected && !isConstrained && connectionType.isReliable
    }

    /// バックグラウンドアップロードに適した接続状態かどうかを判定
    var isOptimalForBackgroundUpload: Bool {
        return isConnected && !isExpensive && !isConstrained
    }

    /// 現在の接続状態の詳細情報を取得
    var connectionDetails: ConnectionDetails {
        return ConnectionDetails(
            isConnected: isConnected,
            connectionType: connectionType,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            isOptimalForUpload: isOptimalForUpload,
            isOptimalForBackgroundUpload: isOptimalForBackgroundUpload
        )
    }

    // MARK: - Private Methods

    private func updateNetworkStatus(path: NWPath) {
        let previousConnectedState = isConnected
        let previousConnectionType = connectionType

        isConnected = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        connectionType = determineConnectionType(path: path)

        // 接続状態変化時のログと処理
        if previousConnectedState != isConnected {
            if isConnected {
                print("📶 [NETWORK] ネットワーク接続が回復しました: \(connectionType.displayName)")
                // 接続復旧時のコールバック実行
                connectionRecoveryCallbacks.forEach { $0() }
            } else {
                print("📵 [NETWORK] ネットワーク接続が失われました")
            }
        }
        
        // 接続タイプ変更時の処理（WiFi ⇄ Cellular切り替え）
        if previousConnectionType.displayName != connectionType.displayName && isConnected {
            print("🔄 [NETWORK] 接続タイプが変更されました: \(previousConnectionType.displayName) → \(connectionType.displayName)")
            // ネットワーク変更時のコールバック実行
            networkChangeCallbacks.forEach { $0(previousConnectionType, connectionType) }
        }

        // 接続品質の変化をログ
        logConnectionQuality()
    }

    private func determineConnectionType(path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        } else if path.usesInterfaceType(.other) {
            return .other
        } else {
            return .unknown
        }
    }

    private func logConnectionQuality() {
        let quality = getConnectionQuality()
        print("接続品質: \(quality.displayName)")

        if isExpensive {
            print("⚠️ 従量制接続が検出されました")
        }

        if isConstrained {
            print("⚠️ 制限された接続が検出されました")
        }
    }

    private func getConnectionQuality() -> ConnectionQuality {
        if !isConnected {
            return .none
        } else if isConstrained || isExpensive {
            return .poor
        } else if connectionType.isReliable {
            return .excellent
        } else {
            return .good
        }
    }
}

// MARK: - Supporting Types

/// 接続品質の定義
enum ConnectionQuality {
    case none
    case poor
    case good
    case excellent

    var displayName: String {
        switch self {
        case .none:
            return "接続なし"
        case .poor:
            return "低品質"
        case .good:
            return "良好"
        case .excellent:
            return "最高"
        }
    }
}

/// 接続詳細情報
struct ConnectionDetails {
    let isConnected: Bool
    let connectionType: NetworkMonitor.ConnectionType
    let isExpensive: Bool
    let isConstrained: Bool
    let isOptimalForUpload: Bool
    let isOptimalForBackgroundUpload: Bool

    var description: String {
        var details = [
            "接続: \(isConnected ? "有効" : "無効")",
            "タイプ: \(connectionType.displayName)",
        ]

        if isExpensive {
            details.append("従量制: 有効")
        }

        if isConstrained {
            details.append("制限: 有効")
        }

        details.append("アップロード最適: \(isOptimalForUpload ? "はい" : "いいえ")")
        details.append(
            "バックグラウンド最適: \(isOptimalForBackgroundUpload ? "はい" : "いいえ")"
        )

        return details.joined(separator: ", ")
    }
}

// MARK: - Publisher Extensions

extension NetworkMonitor {
    /// 接続状態の変化を監視するPublisher
    var connectionStatePublisher: AnyPublisher<Bool, Never> {
        $isConnected
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// 接続タイプの変化を監視するPublisher
    var connectionTypePublisher: AnyPublisher<ConnectionType, Never> {
        $connectionType
            .removeDuplicates { $0.displayName == $1.displayName }
            .eraseToAnyPublisher()
    }

    /// アップロード最適性の変化を監視するPublisher
    var uploadOptimalityPublisher: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest4(
            $isConnected,
            $connectionType,
            $isExpensive,
            $isConstrained
        )
        .map { connected, type, expensive, constrained in
            connected && !constrained && type.isReliable
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
