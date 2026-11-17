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
The app opens on the animated radar map; the gear button opens Settings, whose Debug section
shows the BBOX, WMS URL, HTTP status, radar/fetch times, base map reuse, alignment error,
the animation's frames, and widget memory readings (memory is only reported on a device).

## Generated data

- `RadarGlance/Resources/highways.bin`: highway lines from US Census TIGER/Line primary roads.
  Regenerate with the commands at the top of `tools/build-highways.py`.
- `Shared/RadarPaletteTable.swift`: NOAA radar color → dBZ, measured against nowCOAST. See
  `tools/derive-radar-palette.py` and `docs/noaa-wms-notes.md`.

## Manual checks (can't be automated here)

- [ ] Run on a real iPhone with CarPlay Simulator (Xcode 27 Device Hub → CarPlay Simulator,
      iPhone connected by USB) or in a car.
- [ ] Widget renders with the iPhone **locked**.
- [ ] Refresh button works on a touchscreen head unit.
- [ ] Background stays visible in CarPlay (not removed).
- [ ] Widget extension memory: after a widget refresh, open the app's Debug section and
      check the "Memory" rows from the `widget` process stay well above 8 MB free.
- [ ] Radar animation is smooth on a device while panning and zooming the map.
- [ ] With Settings → Widget → Temperature & humidity on, the widget (Home Screen and CarPlay)
      shows "temp · humidity" top-left without crowding the refresh button.
- [ ] Highway lines and radar read well in each map style and appearance, and each color scheme
      is legible over heavy rain (needs a day with strong storms; the palette above ~40 dBZ is
      extrapolated).
- [ ] Tapping the widget (outside the refresh button) opens the app on the radar map,
      recentered on you; the refresh button still refreshes without opening the app.
- [ ] Radar edges line up with coastlines (needs a day with coastal precipitation;
      the snapshot-corner alignment check reports ~0 px).
