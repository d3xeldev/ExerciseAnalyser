import SwiftUI
import UIKit

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = PhoneModel.shared
        return true
    }
}

@main
struct ExerciseAnalyserPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneContentView(model: PhoneModel.shared)
                .tint(.teal)
                .task { await PhoneModel.shared.foreground() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await PhoneModel.shared.foreground() } }
                }
        }
    }
}
