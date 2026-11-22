import SwiftUI

@main
struct IPAEditorApp: App {
    @StateObject private var ws = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ws)
                .onOpenURL { url in ws.requestLeave { ws.open(url) } }
        }
    }
}
