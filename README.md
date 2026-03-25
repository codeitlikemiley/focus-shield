# 🛡️ Focus Shield

A native **SwiftUI** app for **macOS** and **iOS** that blocks distracting websites and apps so you can stay focused. Toggle your blocklists on and off — when you're done working, turn everything back on.

---

## ✨ Features

| Feature | macOS | iOS |
|---|---|---|
| **Website blocking** | ✅ via `/etc/hosts` | ✅ via Screen Time API |
| **App blocking** | ✅ terminates apps on launch | ✅ via Screen Time API |
| **Per-domain checkboxes** | ✅ | ✅ |
| **Master toggle** | ✅ | ✅ |
| **Menu bar / System tray** | ✅ shield icon | — |
| **Global hotkey** | ✅ configurable | — |
| **Search** | ✅ | ✅ |
| **Persistence** | ✅ JSON | ✅ JSON |

### Default Blocklists

**7 website categories** pre-loaded:
- 🧑‍🤝‍🧑 Social Media — Facebook, Instagram, X/Twitter, LinkedIn, Snapchat, Pinterest, Threads, Tumblr, Mastodon, Bluesky, BeReal, Nextdoor, VK, Weibo
- 💬 Messaging — Discord, Telegram, WhatsApp, Messenger, Signal, Slack, Teams
- 🎬 Video & Streaming — YouTube, TikTok, Twitch, Netflix, Disney+, Hulu, Prime Video, Max, Peacock, Crunchyroll, Spotify
- 💬 Forums — Reddit, Quora, 4chan, Imgur
- 📰 News & Entertainment — Hacker News, BuzzFeed, 9GAG, Bored Panda, Medium
- 🎮 Gaming — Steam, Epic Games, GOG, itch.io, Roblox, EA, Blizzard, Chess.com, Lichess
- 🛒 Shopping — Amazon, eBay, AliExpress, Wish, Etsy, Shopee, Lazada, Temu, Shein

**27 blockable apps** including Steam, Epic Games, Discord, Minecraft, Roblox, Telegram, WhatsApp, Slack, Spotify, Safari, Chrome, Firefox, Arc, and more.

---

## 🚀 Quick Start

### Prerequisites
- macOS 14+ (Sonoma) / iOS 17+
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Run macOS App (fastest)

```bash
# No Xcode project needed — uses Swift Package Manager
cd FocusShield
swift run
```

### Run on iOS Simulator

```bash
cd FocusShield
./build.sh run-ios              # Default: iPhone 16
./build.sh run-ios "iPhone 15"  # Specific device
```

### Open in Xcode

```bash
cd FocusShield
./build.sh generate   # Creates .xcodeproj from project.yml
./build.sh open       # Opens in Xcode
```

---

## 🔨 Build Script

All build commands are available via `./build.sh`:

```
Quick Start:
  generate              Generate Xcode project from project.yml
  run-macos             Build & run macOS app (Swift PM, no Xcode needed)
  run-ios [device]      Build & run on iOS Simulator (default: iPhone 16)

macOS:
  build-macos           Build macOS via Swift PM
  build-macos-xcode     Build macOS via Xcode
  run-macos-xcode       Build & launch macOS via Xcode
  build-macos-signed <TEAM_ID>  Signed macOS build
  archive-macos <TEAM_ID>       Archive for distribution

iOS:
  list-simulators       List available iOS simulators
  build-ios [device]    Build for iOS Simulator
  run-ios [device]      Build, install & launch on Simulator
  build-ios-device <TEAM_ID>  Build for physical iOS device
  archive-ios <TEAM_ID>       Archive for distribution

Other:
  clean                 Remove all build artifacts
  open                  Open in Xcode
```

### Finding your Team ID

Go to **Xcode → Settings → Accounts**, select your Apple ID, and copy the **Team ID** from the team list.

### Signing for Device

```bash
# Build and sign for a physical iPhone
./build.sh build-ios-device YOUR_TEAM_ID

# Build and sign macOS for distribution
./build.sh build-macos-signed YOUR_TEAM_ID
```

---

## 🏗️ Architecture

```
FocusShield/
├── Package.swift              # Swift PM manifest (macOS quick build)
├── project.yml                # XcodeGen spec (macOS + iOS)
├── build.sh                   # Build/run/sign scripts
├── Platforms/
│   ├── macOS/
│   │   ├── Info.plist
│   │   └── FocusShield.entitlements
│   └── iOS/
│       ├── Info.plist
│       └── FocusShield.entitlements
└── Sources/
    ├── Models.swift            # Shared data models
    ├── FocusShieldViewModel.swift   # Shared ViewModel (#if os guards)
    ├── FocusShieldApp.swift    # macOS entry point + MenuBarExtra
    ├── Services/
    │   ├── DataStore.swift          # JSON persistence (shared)
    │   ├── HostsFileService.swift   # /etc/hosts blocking (macOS)
    │   ├── AppMonitorService.swift  # Process monitoring (macOS)
    │   └── ScreenTimeService.swift  # FamilyControls API (shared)
    ├── Views/                  # macOS SwiftUI views
    │   ├── ContentView.swift
    │   ├── WebsiteListView.swift
    │   ├── AppListView.swift
    │   └── SettingsView.swift
    └── iOS/                    # iOS SwiftUI views
        └── FocusShieldiOSApp.swift
```

---

## 🔒 How Blocking Works

### macOS

| Mechanism | How |
|---|---|
| **Websites** | Injects `127.0.0.1 domain.com` into `/etc/hosts` (prompts for admin password), then flushes DNS cache |
| **Apps** | Monitors `NSWorkspace.didLaunchApplicationNotification` and immediately terminates blocked apps |
| **Hotkey** | Uses `NSEvent.addGlobalMonitorForEvents` (requires Accessibility permission) |

### iOS

| Mechanism | How |
|---|---|
| **Websites** | Uses `ManagedSettings` (Screen Time API) to set web content filters |
| **Apps** | Uses `FamilyControls` (Screen Time API) to restrict app launches |

> **Note:** The iOS Screen Time API requires the `com.apple.developer.family-controls` entitlement. You'll need to request this capability in your Apple Developer account.

---

## ⚙️ Configuration

### Global Hotkey (macOS)

1. Open the app → **Settings** tab
2. Click **Record Shortcut**
3. Press your desired key combination (e.g., `⌃⌥⇧S`)
4. The shortcut now toggles Focus Shield from anywhere

> Requires **Accessibility** permission: System Settings → Privacy & Security → Accessibility → Add Focus Shield

### Screen Time Authorization (iOS)

1. Open the app → **Settings** tab
2. Tap **Authorize**
3. Grant Screen Time access when prompted

### Adding Custom Websites

1. Expand a category → click **Add Website**
2. Type the domain (e.g., `example.com`) — `www.` variant is added automatically
3. Use the **checkbox** next to each domain to exclude it while the category is blocked

### Adding Custom Apps

- **Scan**: Click **Scan Apps** to auto-detect games and entertainment apps
- **Manual**: Click **Add App** and enter the bundle identifier
- Find any app's bundle ID:
  ```bash
  osascript -e 'id of app "Visual Studio Code"'
  # Output: com.microsoft.VSCode
  ```

---

## 📱 Screen Time API Notes

The **FamilyControls** entitlement (`com.apple.developer.family-controls`) is required for iOS and optional for macOS. To request it:

1. Go to [developer.apple.com/account](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Profiles** → **Identifiers**
3. Select your app ID → enable **Family Controls**
4. Regenerate your provisioning profile

For development and testing on your own devices, the entitlement works without App Store distribution.

---

## 📜 License

MIT
