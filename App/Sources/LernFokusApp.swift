import BackgroundTasks
import LernKern
import SwiftUI

@main
struct LernFokusApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear { model.onLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.onForeground()
            case .background: model.onBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await MainActor.run { model.backgroundRefresh() }
        }
    }
}

/// Hintergrundaktualisierung als Sicherheitsnetz, falls ein DeviceActivity-Rückruf ausbleibt.
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.example.lernfokus") + ".refresh" }

    static func schedule(after date: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        let fallback = Date().addingTimeInterval(30 * 60)
        request.earliestBeginDate = min(max(date ?? fallback, Date().addingTimeInterval(5 * 60)), Date().addingTimeInterval(6 * 3600))
        try? BGTaskScheduler.shared.submit(request)
    }
}
