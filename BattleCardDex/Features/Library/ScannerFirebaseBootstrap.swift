import DeviceCheck
import FirebaseAppCheck
import FirebaseCore
import Foundation

nonisolated func scannerLog(_ message: @autoclosure () -> String) {
#if DEBUG
    print(message())
#endif
}

nonisolated final class ScannerProductionAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> (any AppCheckProvider)? {
        if DCAppAttestService.shared.isSupported { return AppAttestProvider(app: app) }
        return DeviceCheckProvider(app: app)
    }
}

@MainActor
enum ScannerFirebaseBootstrap {
    static var usesDebugProvider: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["BATTLE_CARD_DEX_USE_APP_CHECK_DEBUG_PROVIDER"] == "1"
#else
        false
#endif
    }

    static func configure() throws {
        guard FirebaseApp.app() == nil else { return }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path), options.bundleID == Bundle.main.bundleIdentifier else {
            throw ScannerFailure.message("Recognition is unavailable because the app’s Firebase configuration is missing.")
        }
#if DEBUG
        if usesDebugProvider {
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        } else {
            AppCheck.setAppCheckProviderFactory(ScannerProductionAppCheckFactory())
        }
#else
        AppCheck.setAppCheckProviderFactory(ScannerProductionAppCheckFactory())
#endif
        FirebaseApp.configure(options: options)
    }
}

@MainActor
protocol CardRecognizing: Sendable {
    func recognize(text: String) async throws -> [BattleCardDetail]
    func recognize(text: String, onDiagnostics: (ScanRecognitionDiagnostics) -> Void) async throws -> [BattleCardDetail]
}

extension CardRecognizing {
    func recognize(text: String, onDiagnostics: (ScanRecognitionDiagnostics) -> Void) async throws -> [BattleCardDetail] {
        try await recognize(text: text)
    }
}
