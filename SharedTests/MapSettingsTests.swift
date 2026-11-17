import Foundation
import Testing
@testable import Shared

struct MapSettingsTests {
    @Test func defaultsKeepTodaysLook() {
        let settings = SharedStore(defaults: temporaryDefaults()).mapSettings
        #expect(settings.appearance == .dark)
        #expect(settings.style == .muted)
        #expect(settings.colorScheme == .noaa)
        #expect(settings.radarOpacity == 0.75)
        #expect(settings.showsHighways)
        #expect(!settings.hidesLightReturns)
        #expect(settings.animationSpeed == .normal)
        #expect(!settings.smoothRadar)
    }

    @Test func roundTrip() {
        let store = SharedStore(defaults: temporaryDefaults())
        var settings = MapSettings()
        settings.appearance = .light
        settings.style = .satellite
        settings.colorScheme = .colorBlind
        settings.hidesLightReturns = true
        settings.radarOpacity = 0.4
        settings.animationSpeed = .fast
        settings.smoothRadar = true
        settings.showsHighways = false
        store.mapSettings = settings
        #expect(store.mapSettings == settings)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(MapSettings.self, from: Data(#"{"style":"standard"}"#.utf8))
        var expected = MapSettings()
        expected.style = .standard
        #expect(decoded == expected)
    }
}
