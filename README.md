# LifeboatKit

The Swift package for [Lifeboat](https://getlifeboat.app): a way for apps without logins to keep a confirmed email list they own, so they can reach their users if the app moves, needs a critical fix, or ships something new.

It gives you a signup sheet, a settings screen, and `askIfDue()`, which asks at most 3 times a year per person, at least 30 days apart, and never again after someone unsubscribes. Addresses join your list only after their owner confirms by email.

Requires iOS 17 or macOS 14.

## Install

In Xcode: **File → Add Package Dependencies…**, enter

```
https://github.com/getlifeboat-app/lifeboat-swift
```

and add the `LifeboatKit` library to your app target. Or in `Package.swift`:

```swift
.package(url: "https://github.com/getlifeboat-app/lifeboat-swift", from: "1.0.0")
```

## Use

```swift
import LifeboatKit

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Lifeboat.shared.configure(appKey: "lb_pub_test_…")
        #else
        Lifeboat.shared.configure(appKey: "lb_pub_live_…")
        #endif
    }
    var body: some Scene {
        WindowGroup { ContentView().lifeboatAsk(appName: "My App") }
    }
}

// Right after the person finishes something (not at launch, not mid-task):
await Lifeboat.shared.askIfDue()

// In Settings:
NavigationLink("Email updates") { LifeboatPreferencesView(appName: "My App") }
```

Get your keys from the [dashboard](https://getlifeboat.app). Public keys can only add a subscriber; they can't read or export your list.

## Match your app's design

Pass a `LifeboatAppearance`: colours (including an error colour) for light and dark, corner radius, title typeface and weight or your own font, and the icon on the Check your inbox screen. Colours and radius can also be set in the dashboard; values set in code win.

The consent wording, the unsubscribe line, and News & offers starting off are the same in every app, so people always know what they are agreeing to.

## Your own version

Need more than the options cover? The kit is plain Swift under the MIT license: copy `Sources/LifeboatKit` into your project and change what you like. You then update your copy yourself instead of getting fixes through the package. Keep the unsubscribe line in the wording you send: the API refuses a signup without it (`consent_required`).

## Docs

- [SwiftUI guide](https://getlifeboat.app/docs/swiftui)
- [Quick start](https://getlifeboat.app/docs/quick-start)
- [For AI coding tools](https://getlifeboat.app/llms.txt)

## Privacy

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`). It sends the email address a person types, and anonymous counts (which ask this was, launches and days since install, in ranges) with no device or user id. No tracking.

## License

MIT
