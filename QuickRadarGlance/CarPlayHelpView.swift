import SwiftUI

struct CarPlayHelpView: View {
    var body: some View {
        List {
            Section("Add the widget to CarPlay") {
                Label("Open Settings on your iPhone", systemImage: "1.circle")
                Label("Go to General → CarPlay", systemImage: "2.circle")
                Label("Choose your car", systemImage: "3.circle")
                Label("Open Widgets and add QuickRadarGlance", systemImage: "4.circle")
            }
            Section {
                Text("""
                    The widget refreshes about every 5 minutes; the system may refresh it \
                    less often. Tap the ↻ button on the widget to fetch the newest radar. \
                    Taps within 30 seconds of the last refresh are ignored.
                    """)
                Text("""
                    Location must be set to While Using or Always for the widget to follow you.
                    """)
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("CarPlay")
    }
}
