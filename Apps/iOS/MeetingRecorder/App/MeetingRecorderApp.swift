import SwiftUI

@main
struct MeetingRecorderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.library)
                .environmentObject(app.connection)
                .environmentObject(app.recorder)
                .environmentObject(app.uploader)
                .onOpenURL { app.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Make sure the uploader exists even when the system launched the app without a window.
        _ = AppModel.shared
        return true
    }

    /// The system finished uploads while the app wasn't running and has woken it to say so.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppModel.shared.uploader.backgroundEventsCompletion = completionHandler
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if app.isPaired { MainView() } else { PairingView() }
        }
        .alert("Meeting Recorder", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alert ?? "")
        }
    }
}
