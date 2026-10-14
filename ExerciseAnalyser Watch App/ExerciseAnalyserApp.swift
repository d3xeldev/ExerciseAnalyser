import SwiftUI

@main
struct ExerciseAnalyser_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await AppModel.shared.foreground() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await AppModel.shared.foreground() } }
                }
        }
    }
}
