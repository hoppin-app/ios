# hoppin — iOS app

The hoppin iPhone app: SwiftUI, iOS 18+, Swift 6 concurrency. Messages are
end-to-end encrypted and travel over the local network, a Bluetooth mesh, or
the relay in the `server` repo.

Part of the [hoppin](https://github.com/hoppin-app/hoppin) project; clone that
parent repo to get every part side by side.

## Build and run

Open `HopChat-1.xcodeproj` in Xcode 26 and run the `HopChat-1` scheme on an
iPhone simulator or device.

## Tests

```bash
# Unit + UI tests. The cross-language tests need the lib repo's fixtures:
# ../lib (parent checkout) or ./lib (as CI checks it out).
xcodebuild test -project HopChat-1.xcodeproj -scheme HopChat-1 \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Everything, against a real local server (from the parent checkout):
lib/run_tests.sh
```

## More

- Code map and conventions: [`HopChat-1/CLAUDE.md`](HopChat-1/CLAUDE.md)
- Protocol spec: `DESIGN_CONTRACT.md` in the `docs` repo
- App Store text, screenshots and compliance: `app-store/` in the `docs` repo
- Store screenshot frames: `swift scripts/make_store_shots.swift` (reads and
  writes `../docs/app-store/screenshots`)
