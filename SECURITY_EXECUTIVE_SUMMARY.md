# FocusShield Security Model: Executive Summary

## The Core Problem

AI agents with "computer use" capabilities (Claude Code, Codex, OpenClaw) can now:
- Launch apps and browsers
- Execute shell commands
- Read your files
- Make network requests

**The dilemma:**
- **Sandbox ON** → AI can't do useful work (can't access tools, configs, codebase)
- **Sandbox OFF** → AI can exfiltrate your credentials (`.env`, API keys, tokens)

Claude Code's sandbox addresses this with Seatbelt (macOS) + network proxy, but it only applies to Claude's bash commands — not GUI apps, not other AI tools.

---

## FocusShield's Solution

FocusShield provides **system-level enforcement** that works **regardless of any AI agent's sandbox state**.

### Architecture: 8 Layers of Defense

```
┌─────────────────────────────────────────────────────────────┐
│ AI AGENT (Claude, Codex, OpenClaw)                          │
│  └─ Optional internal sandbox (Claude's Seatbelt)          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. CLI PREFLIGHT GUARD                                      │
│    • Inspects command arguments                             │
│    • Extracts domain names                                  │
│    • Scans for API keys/secrets                             │
│    • Detects invisible Unicode (zero-width, homoglyphs)     │
│    • Interactive prompts: Allow/Block                       │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. CLI FILESYSTEM SANDBOX                                   │
│    • Per-tool Seatbelt profile                              │
│    • Read/write whitelist or blacklist                      │
│    • Baseline secret + persistence path protection          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. NETWORK EXTENSION (Kernel-level)                         │
│    • Intercepts ALL socket flows                            │
│    • Identifies app by bundle ID                            │
│    • Per-app whitelist/blacklist                            │
│    • Cannot be bypassed                                     │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. PAC PROXY + BROWSER POLICIES                             │
│    • Per-browser proxy configuration                        │
│    • Chrome/Firefox/Brave/Edge/Safari                       │
│    • Managed policy enforcement                             │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. PF FIREWALL                                              │
│    • IP-level blocking                                      │
│    • Catches QUIC/HTTP/3 bypass                             │
│    • Transport-layer backstop                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. /etc/hosts                                               │
│    • DNS-level blocking                                     │
│    • Legacy resolver fallback                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 7. APP MONITOR                                              │
│    • Watches for blocked app launches                       │
│    • Terminates prohibited processes                        │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 8. (Future) ENDPOINT SECURITY                               │
│    • File access monitoring                                 │
│    • Real-time blocking                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## How It Compares to Claude's Sandbox

| Feature | Claude Sandbox | FocusShield |
|---------|---------------|-------------|
| **Scope** | Only Claude's bash commands | All apps, all CLI tools |
| **Filesystem** | Seatbelt (macOS) | Seatbelt-backed CLI policy + (future) ESF for GUI/system-wide file events |
| **Network** | Proxy-based | Kernel extension + PAC + pf |
| **Per-app rules** | ❌ No | ✅ Yes |
| **Works when AI sandbox OFF** | ❌ No | ✅ Yes |
| **CLI preflight inspection** | ❌ No | ✅ Yes (args, stdin, files) |
| **Payload pattern detection** | ❌ No | ✅ Yes (API keys, secrets) |
| **Invisible character detection** | ❌ No | ✅ Yes (zero-width, RTL) |

---

## Key Use Cases

### 1. Lock AI Agent to Specific Domains

```bash
# Configure in FocusShield app:
# Tool: claude
# Mode: Whitelist  
# Domains: anthropic.com, github.com

# Result:
claude "help me code"              # ✅ Works
claude "curl my-secrets-to-evil"   # ❌ BLOCKED (domain not in whitelist)
```

### 2. Inline Domain Addition (No GUI)

```bash
# Add to whitelist on-the-fly
l=w curl https://api.example.com/data

# Short syntax: l=w (whitelist), l=b (blacklist)
l=b curl https://facebook.com
```

### 3. Protect Against Prompt Injection

**Attack:** Hidden prompt tricks AI into exfiltrating `.env`
**Defense:** 
- Pattern detection blocks API key exfiltration
- Domain whitelist prevents reaching unknown servers
- Invisible character detection catches obfuscated commands

---

## Future Enhancements

### Delivered: Seatbelt Integration For CLI Tools

CLI wrappers now generate and use `sandbox-exec` profiles with:
- baseline denies for common credential and persistence paths
- per-tool read-mode and write-mode controls
- explicit path lists for allowlist or denylist behavior

### Still missing compared with Docker-style sandboxes

- microVM isolation and a private Docker daemon
- read-only secondary workspace mounts
- credential injection / request brokering for all traffic
- GUI-app filesystem enforcement
- Unix socket / local IPC policy

### Phase 2: Endpoint Security Framework
Real-time file access monitoring:
- Block AI from reading `~/.ssh`, `~/.aws`, `~/.env`
- Alert on suspicious file access patterns

### Phase 3: TCC Monitoring
Detect when AI agents request:
- Accessibility permissions (UI control)
- Screen capture (exfiltration risk)
- AppleEvents (control other apps)

---

## The Bottom Line

**Current state:** You choose between usable AI (sandbox OFF) and secure AI (sandbox ON).

**FocusShield enables:** Usable AND secure AI.

- Turn sandbox OFF → AI can access your codebase, use your tools
- FocusShield ON → AI can only reach approved domains, cannot exfil credentials

This is **defense-in-depth for the AI era** — system-level enforcement that persists regardless of what the AI thinks its permissions are.

---

## Quick Start

```bash
git clone https://github.com/goldcoders/blacksheep/FocusShield
cd FocusShield
make install
make run

# In the app:
# 1. Go to CLI tab
# 2. Add /usr/local/bin/claude
# 3. Set mode to Whitelist
# 4. Add anthropic.com
# 5. Enable payload protection

# Done. Your AI agent is now contained.
```

---

## Documentation

- Full Architecture: `SANDBOX_ARCHITECTURE.md`
- README: `README.md`
- Source: `/Sources`

---

*FocusShield: System-level security for AI agents*
