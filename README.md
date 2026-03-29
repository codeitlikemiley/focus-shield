# 🛡️ Focus Shield

A native **SwiftUI** app for **macOS** and **iOS** that blocks distracting websites, GUI applications, and CLI tools so you can stay focused. Toggle your blocklists on and off via the Menu Bar, or switch between custom Profiles for different work environments.

---

## ✨ Features

| Feature | macOS | iOS |
|---|---|---|
| **Website blocking** | ✅ Network Extension + DNS Proxy + PAC + pf firewall | ✅ via Screen Time API |
| **Per-browser blocking** | ✅ Network Extension + browser-specific PAC/policy | — |
| **App blocking** | ✅ Network Extension + process termination + pf | ✅ via Screen Time API |
| **CLI Tool blocking** | ✅ wrapper + preflight guard + network backstop | — |
| **CLI Payload Guard** | ✅ regex-based prompt/deny for configured CLI tools | — |
| **On-demand domain add** | ✅ `l=w` / `l=b` env var inline with any command | — |
| **Profiles** | ✅ Unlimited custom profiles | ✅ |
| **Global / Per-App / Per-CLI Rules** | ✅ | — |
| **Master toggle** | ✅ | ✅ |
| **Menu bar integration** | ✅ | — |
| **Global hotkey** | ✅ configurable | — |
| **Persistence** | ✅ SQLite | ✅ SQLite |

---

## 🚀 Quick Start

### Prerequisites
- macOS 14+ (Sonoma) / iOS 17+
- Xcode 15+

### Build, Install & Run (macOS)

```bash
cd FocusShield
make install
make run
```

Useful targets:

```bash
make help
make release
make verify
make open
make uninstall
```

> `make install` prompts for your admin password **once** to install the privileged helper. After that, toggling the shield requires no password.
>
> `make build` and `make release` are SwiftPM-only development builds and do **not** include the Network Extension system extension. Use `make install`, `make run`, or the explicit signed targets when you need the full macOS enforcement stack.

If `.env` contains `TEAM_ID=5KZ8MD34QW`, then:
- `make install` uses the signed Xcode build automatically
- `make run` uses the signed Xcode build automatically
- you do not need `make run-macos-signed` for normal development

### Signing Defaults

Create a local `.env` file so you do not need to pass `TEAM_ID` every time:

```bash
cp env.example .env
```

Then set:

```bash
TEAM_ID=5KZ8MD34QW
```

After that, the normal commands already use the signed path:

```bash
make install
make run
```

The explicit signed targets still exist for advanced use:

```bash
make build-macos-signed
make install-macos-signed
make run-macos-signed
```

### Open in Xcode

```bash
make generate-xcode
make open-xcode
```

---

## 🔒 How Blocking Works (macOS) — Architecture

Focus Shield has a **control plane** and multiple **enforcement layers**. The Network Extension is the primary per-app filtering engine. The hosts/PAC/pf/DNS/CLI stack is the compatibility and defense-in-depth layer around it.

### Control Plane

| Component | File | Role |
|---|---|---|
| **SwiftUI host app** | `Sources/FocusShieldViewModel.swift` | Owns profiles, activation, UI state, and enforcement orchestration |
| **SQLite store** | `Sources/Services/DataStore.swift` | Persists `profiles`, `app_rules`, `domain_rules`, `settings`, payload patterns, and lists |
| **Network filter manager** | `Sources/Services/NetworkFilterManagerService.swift` | Activates the system extension and syncs `NEFilterManager` vendor configuration |
| **Legacy network materializer** | `Sources/Services/HostsFileService.swift` | Generates hosts entries, pf rules, PAC files, browser policy files, DNS proxy inputs, and CLI wrappers |
| **Privileged helper** | `install.sh` + generated `focusshield-helper` | Performs root-only writes to `/etc/hosts`, `/etc/pf.anchors`, `/Library/Managed Preferences`, and `/usr/local/bin` |

### Enforcement Plane

| Layer | Scope | Under the hood |
|---|---|---|
| **Network Extension** | Per-app socket flows | `FocusShieldFilterDataProvider` resolves the source bundle ID from the audit token, extracts the destination host, and returns allow/drop verdicts |
| **Per-browser PAC + managed policy** | Chrome, Firefox, Brave, Edge, Safari fallback | Focus Shield serves browser-specific PAC endpoints and installs managed policy files so each browser gets its own ruleset |
| **`/etc/hosts`** | Legacy resolver path | Static resolver backstop for domains that still honor hosts-based blocking |
| **Local DNS proxy** | Resolver path | Additional domain enforcement when requests go through the local Focus Shield DNS process |
| **pf firewall** | Transport backstop | IP-level blocking for TCP and UDP, including QUIC/HTTP/3 bypass attempts |
| **App monitor** | Fully blocked GUI apps | Watches launches and terminates apps that are configured as fully blocked |
| **CLI wrappers + guard** | Linked CLI tools | Wrapper scripts inspect command args/stdin/files, enforce domain mode, and optionally prompt on sensitive payloads before exec |

### Why both Network Extension and legacy layers?

- **Safari/WebKit and transport-aware per-app filtering** require Apple's Network Extension path.
- **Managed browsers** like Chrome and Firefox can still be steered very effectively with browser-specific PAC and policy files.
- **QUIC, DoH, and direct socket flows** need transport-aware blocking plus a kernel backstop.
- **CLI tools** need pre-execution inspection, not just network-layer blocking, because the command line itself reveals intent and payload context.

## 🎯 Per-App Rules Under The Hood

When you add an app or browser in the **Apps** tab, Focus Shield does more than store a label in the UI:

1. The rule is persisted into SQLite as an `app_rules` row plus zero or more `domain_rules`.
2. Activating a profile builds a `ProfileNetworkPolicy` from the active profile, global domains, app overrides, CLI rules, and fully blocked apps.
3. `NetworkFilterManagerService` turns app-specific rules into a compact `NetworkFilterPolicy`, submits the system extension activation request, and saves that policy into `NEFilterManager.providerConfiguration.vendorConfiguration`.
4. Inside the system extension, `FocusShieldFilterDataProvider` receives each new socket flow, resolves the real source bundle ID from the audit token, extracts the destination host, and applies the profile decision in-process.
5. In parallel, `HostsFileService` generates browser-specific PAC files and managed browser policies so Chromium-family browsers and Firefox follow the same profile through their policy systems.
6. If an app is marked as fully blocked, `AppMonitorService` acts as a behavioral backstop by terminating the app on launch.

This means **Safari and other socket-level apps rely on the Network Extension**, while managed browsers also get a browser-policy path, and fully blocked apps get a process-level guard.

---

## 🌐 Per-Browser PAC Routing

Each browser is served a **separate PAC file** generated from its own per-app domain rules:

| Browser | PAC URL | How it's configured |
|---|---|---|
| **Safari** | `http://127.0.0.1:9876/safari.pac` | macOS system proxy (all system proxy users get this) |
| **Chrome** | `http://127.0.0.1:9876/chrome.pac` | `/Library/Managed Preferences/com.google.Chrome.plist` |
| **Firefox** | `http://127.0.0.1:9876/firefox.pac` | Firefox proxy autoconfig |
| **Brave** | `http://127.0.0.1:9876/brave.pac` | Brave managed preferences |
| **Edge** | `http://127.0.0.1:9876/edge.pac` | Edge managed policy |

### How Chrome managed preferences work

FocusShield writes `/Library/Managed Preferences/com.google.Chrome.plist` (requires root — done via the privileged helper). **This works on any Mac**, not just enterprise-enrolled ones. Chrome reads this location for system policy on every launch.

> **Chrome will show a banner: "This browser is managed"** — this is expected and correct. It means FocusShield's proxy policy is active.

To verify Chrome policy is loaded: open `chrome://policy` in Chrome. You should see `ProxySettings` listed.

---

## 🎯 Per-App Domain Rules (Apps Tab)

Each browser/app added in the **Apps tab** can have its own domain filter that **overrides the global rules for that target**. For managed browsers this becomes a PAC override; for Network Extension-backed apps it becomes a per-bundle filter rule.

| Mode | Domains | Effect |
|---|---|---|
| **Blacklist** | `facebook.com`, `twitter.com` | Block those domains **in addition to** the global list |
| **Blacklist** | *(empty)* | This browser is **unrestricted** — global block list bypassed in its PAC |
| **Whitelist** | `apple.com`, `developer.apple.com` | Browser can **only** visit those domains — everything else blocked |
| **Inherit Global** | — | Uses the same rules as the global profile setting |

### Example: Lock Safari to Apple domains only

1. Go to **Apps tab** → Add `Safari`
2. Set **Domain Filter → Whitelist**
3. Add `apple.com`
4. Safari can now only visit `*.apple.com` — all other sites are blocked

---

## 🖥️ Per-CLI Rules Under The Hood

CLI tools use a different path than GUI apps because a terminal command exposes information before any socket is opened.

1. A linked CLI tool is stored as an `app_rules` row with `ruleType = cliTool` and its `executablePath`.
2. On profile activation, `HostsFileService` builds a wrapper for each linked tool under `/usr/local/lib/focusshield/wrappers/`.
3. The privileged helper symlinks those wrappers into `/usr/local/bin/<tool>` and preserves any pre-existing real binary in `/usr/local/lib/focusshield/saved/`.
4. Interactive shells get matching aliases from `update_aliases.sh`, while fresh subprocesses pick up the wrapper via `PATH`.
5. Each wrapper exports the tool's current filter mode and domain rules, then calls `focusshield-cli-guard`.
6. The guard scans command arguments, piped stdin, and referenced files for destination hosts, enforces whitelist/blacklist rules, optionally prompts on payload regex hits, and only then `exec`s the real binary.

CLI tools therefore have **two layers of protection**:

1. **Full block** (`isBlocked = true`): the wrapper exits immediately and the global network stack stays active as a backstop.
2. **Preflight guard** (Whitelist/Blacklist + Payload Protection): the wrapper inspects visible destination hosts in command arguments/stdin/files, blocks disallowed hosts, and can prompt on sensitive payload regex matches before the command executes.

### Example: Allow Claude Code to only access Anthropic

1. Go to **CLI tab** → Add `/usr/local/bin/claude`
2. Set **Domain Filter → Whitelist**
3. Add `anthropic.com`
4. The CLI guard wrapper will only allow `claude` to reach `anthropic.com`

---

## ⚡ On-Demand Domain Management (`l=` / `list=`)

Add domains to a CLI tool's whitelist or blacklist **inline** — no app interaction needed:

```bash
# Short form
l=w curl https://api.example.com/data      # add example.com to whitelist
l=b curl https://facebook.com               # add facebook.com to blacklist

# Long form
list=whitelist curl https://api.openai.com/v1/chat    # add openai.com to whitelist
list=black ping reddit.com                             # add reddit.com to blacklist
```

### How it works

The `l=` / `list=` env var is read by the CLI guard wrapper at runtime:

1. The guard extracts hostnames from your command arguments
2. Writes them to the FocusShield SQLite database (permanent — survives restarts)
3. Updates the in-memory domain list for immediate enforcement
4. Executes through the normal guard flow

The domain is persisted in the database, so it appears in the app UI and applies to all future executions — you only need `l=w` once per domain.

### Accepted values

| Env var | Value | Effect |
|---|---|---|
| `l=w` | whitelist | Add extracted domains to the tool's whitelist |
| `l=b` | blacklist | Add extracted domains to the tool's blacklist |
| `list=white` | whitelist | Long form |
| `list=whitelist` | whitelist | Explicit long form |
| `list=black` | blacklist | Long form |
| `list=blacklist` | blacklist | Explicit long form |

### Piping still works

The env var is scoped to the command, so pipes behave naturally:

```bash
l=w curl -fsSL https://example.com/install.sh | bash
```

This adds `example.com` to the whitelist, downloads the script, and pipes it to `bash` — identical to how you'd normally run it, just with `l=w` prepended.

### Shell compatibility

| Shell | Syntax | Works? |
|---|---|---|
| **zsh** | `l=w curl ...` | ✅ |
| **bash** | `l=w curl ...` | ✅ |
| **dash / sh** | `l=w curl ...` | ✅ |
| **fish** | `env l=w curl ...` | ✅ (fish requires `env` prefix) |

### Requirements

- The CLI tool must already be **linked** in the Focus Shield app (CLI tab)
- The master toggle must be **enabled**
- If the tool isn't linked, you'll see: `focusshield: no CLI rule found for 'curl'. Add it in the app first.`

---

## 🔄 How Changes Propagate

When you modify rules in the app (link/unlink CLI, toggle domains, switch strategy), FocusShield immediately regenerates the wrapper scripts on disk:

| Scenario | Interactive Terminal | AI Tool Calls / Scripts |
|---|---|---|
| **Domain added/removed** | ⚠️ Needs a new shell or `source ~/.zshrc` / `source ~/.bashrc` | ✅ Immediate |
| **Blacklist ↔ Whitelist** | ⚠️ Needs a new shell or re-source | ✅ Immediate |
| **Link/Unlink CLI** | ⚠️ Alias cached in current shell | ✅ Immediate |
| **Profile switch** | ⚠️ Existing shell aliases persist | ✅ Immediate |

**Why AI/script calls work immediately:** Each command spawns a fresh shell that resolves `curl` via PATH. Since `/usr/local/bin` (where our wrappers live) comes first in PATH, it always picks up the latest wrapper.

**Why interactive terminals are stale:** Your shell loads aliases once at startup. The alias takes precedence over PATH. Open a new terminal window or re-source `~/.zshrc` / `~/.bashrc` to pick up changes.

---

## 🔮 Planned: Deep App Payload Inspection (Epic HUG-27)

> **Status: Partial** — CLI wrappers ship today; deeper app/browser payload interception still requires extending the current Apple Network Extension path

Shipped now:
- Regex-based payload detection for configured CLI wrappers
- Prompt flow with session/permanent allow decisions
- Secret pattern catalog for common API-key formats
- On-demand domain management via `l=` / `list=` env vars

Still planned:
- Browser and GUI-app payload interception before bytes leave the device
- gRPC, WebSocket, SSH, and opaque TCP/UDP stream inspection
- True per-app transport-aware filtering across protocols

The remaining work requires extending the current Network Extension path beyond host-based decisions, and it remains bounded by Apple's Network Extension APIs.

### Network Extension Status

The Network Extension (Content Filter Provider) is built and bundled as a system extension (`com.focusshield.macos.filter-data`). It provides Safari and transport-aware per-app blocking.

#### Enabling the extension

The app will show an **"Open Network Extensions Settings"** button in the Settings and Apps views whenever the extension isn't active. Clicking it opens the right System Settings page directly.

When you come back from System Settings, Focus Shield refreshes the system-extension state automatically so the Settings and Apps views reflect approval or enablement without a relaunch.

If you prefer to navigate manually:

1. Open **System Settings** → **General** → **Login Items & Extensions**
2. Find **Focus Shield** in the list, click the `ℹ️` button
3. In the popup, toggle on **Focus Shield Filter** under "Network Extensions"

#### Debug vs Release builds

| Build | System Extension | Why |
|---|---|---|
| **Release** | ✅ Works normally | macOS allows signed extensions to activate |
| **Debug** | ❌ Cannot activate | `get-task-allow` entitlement prevents system extension loading |

> **Debug builds:** macOS refuses to load system extensions signed with `get-task-allow=true`. The app will show an orange message explaining this — it's a macOS restriction, not a bug. Use `make install`, `make run`, or `make install-macos-signed` with a valid `TEAM_ID` for a build that can activate the extension.

#### Developer Portal requirement

The App ID `com.focusshield.macos.filter-data` must have the **"Network Extension — Content Filter Provider"** capability enabled on [developer.apple.com](https://developer.apple.com/account/resources/identifiers).

---

## 📱 iOS Support (Screen Time API)

The iOS version uses Apple's Screen Time API via `ManagedSettings` and `FamilyControls`.

> **Note:** Requires the `com.apple.developer.family-controls` entitlement.

---

## 🛠️ Debugging

```bash
# Check whether macOS sees the sysext at all
systemextensionsctl list | grep focusshield

# Verify pf rules are loaded (should show blocked IPs)
sudo pfctl -a com.focusshield -sr

# Check which PAC file Safari is using
curl http://127.0.0.1:9876/safari.pac

# Check Chrome's PAC
curl http://127.0.0.1:9876/chrome.pac

# Verify Chrome policy loaded
# Open chrome://policy in Chrome → look for ProxySettings

# Check DNS proxy is running
cat /tmp/focusshield-dns.pid | xargs ps -p

# Test DNS blocking
dig facebook.com @127.0.0.1

# Check /etc/hosts entries
grep -A50 'FocusShield START' /etc/hosts

# Test CLI enforcement
curl https://facebook.com          # should be blocked if on blacklist
l=w curl https://example.com       # add to whitelist on the fly

# Monitor Network Extension activation (if enabled)
log stream --predicate 'subsystem == "com.focusshield.macos"' --style compact

# Inspect CLI wrapper content
cat /usr/local/lib/focusshield/wrappers/curl

# Check what domains are baked into a wrapper
grep DOMAIN_RULES_B64 /usr/local/lib/focusshield/wrappers/curl | \
  cut -d'"' -f2 | base64 -D

# Verify wrapper symlink
ls -la /usr/local/bin/curl
```

---

## 📂 File Locations

| File | Purpose |
|---|---|
| `~/Library/Application Support/FocusShield/focusshield.sqlite` | Database (profiles, rules, domains) |
| `~/Library/Application Support/FocusShield/proxy.pac` | PAC file for Safari/system proxy |
| `/usr/local/lib/focusshield/wrappers/` | CLI wrapper scripts |
| `/usr/local/lib/focusshield/focusshield-cli-guard` | CLI preflight guard (POSIX `/bin/sh`) |
| `/usr/local/lib/focusshield/focusshield-domain-add` | On-demand domain-add helper |
| `/usr/local/lib/focusshield/saved/` | Saved original binaries replaced by wrapper symlinks |
| `/usr/local/bin/<tool>` | Symlinks to wrappers (e.g., `curl` → `wrappers/curl`) |
| `/Library/Managed Preferences/com.google.Chrome.plist` | Chrome proxy policy |
| `/tmp/focusshield-dns.pid` | DNS proxy PID file |

---

## 📜 License
MIT
