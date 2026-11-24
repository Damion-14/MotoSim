import SwiftUI

@main
struct MotoSimApp: App {
    var body: some Scene {
        WindowGroup {
            RideView()
                .preferredColorScheme(.dark)
        }
    }
}
