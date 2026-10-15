import SwiftUI

@main
struct VibeBridgeApp: App {
    @StateObject private var hub = Hub()

    var body: some Scene {
        MenuBarExtra {
            ContentView(hub: hub)
        } label: {
            Image(systemName: hub.problem == nil ? "point.3.connected.trianglepath.dotted" : "exclamationmark.triangle")
        }
        .menuBarExtraStyle(.window)
    }
}
