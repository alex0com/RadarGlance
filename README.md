# Radar Glance

A CarPlay Dashboard widget showing live NOAA MRMS radar (continental US) centered on your
position. See `PLAN.md` for the design and `docs/noaa-wms-notes.md` for the NOAA service notes.

## Build

```sh
xcodegen generate          # after editing project.yml
xcodebuild -scheme RadarGlance -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme RadarGlance -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Install on a device (team XXXXXXXXXX, automatic signing):

```sh
xcodebuild -scheme RadarGlance -destination 'id=<device-udid>' -derivedDataPath build/DerivedData -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> build/DerivedData/Build/Products/Debug-iphoneos/RadarGlance.app
```

Simulator testing without GPS: launch with `-testLocation 35.47,-97.52`.
The app's Debug section shows the BBOX, WMS URL, HTTP status, radar/fetch times, base map
reuse, alignment error, and widget memory readings (memory is only reported on a device).

## Manual checks (can't be automated here)

- [ ] Run on a real iPhone with CarPlay Simulator (Xcode 27 Device Hub → CarPlay Simulator,
      iPhone connected by USB) or in a car.
- [ ] Widget renders with the iPhone **locked**.
- [ ] Refresh button works on a touchscreen head unit.
- [ ] Background stays visible in CarPlay (not removed).
- [ ] Widget extension memory: after a widget refresh, open the app's Debug section and
      check the "Memory" rows from the `widget` process stay well above 8 MB free.
- [ ] Radar edges line up with coastlines (needs a day with coastal precipitation;
      the snapshot-corner alignment check reports ~0 px).
