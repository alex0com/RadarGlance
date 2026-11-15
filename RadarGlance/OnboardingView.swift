import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "location.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            Text("Radar where you are")
                .font(.title.bold())
            Text("""
                Radar Glance shows live NOAA weather radar centered on your position, \
                here and in the CarPlay widget.

                The widget can only use your location if you allow it here first. \
                Your location is used to choose the map area and isn't sent anywhere \
                except as the map area in the NOAA radar request.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.requestLocationPermission()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
}
