# Jarvis

A voice-first assistant for macOS. Say "Jarvis", or press a shortcut from any app, and ask. It answers out loud, and it can operate your Mac while you watch: your apps, files, calendar, messages, music, settings, disk space and screen.

## What it can do

**Talk and listen**
- Always-on wake word ("Jarvis"), recognised on this Mac. While idle it only checks the mic level, and it adapts to the room's background noise
- Answers are spoken (Mac voices, your Personal Voice, or Gemini studio voices) and shown as short, copiable text
- Optional voice match: learns your voice from five phrases and ignores other people and the TV

**Get things done**
- Calendar, Reminders, Contacts, Notes, Messages and Mail (sending always asks you first)
- Media keys, volume, brightness, dark mode, Wi-Fi, lock screen, sleep display
- Open, quit and switch apps; find, open and read files (PDF, Word, RTF, text)
- Web search with sources, and reading web pages
- Your Shortcuts, plus a `jarvis://` URL scheme so Siri and Shortcuts can call Jarvis
- Scheduled automations, timers, and facts it remembers about you
- Screen control: it looks at the screen, moves the real cursor, clicks and types, showing each step. Esc stops it at any time
- Open-source tool servers through the Model Context Protocol (MCP)

**Look after your Mac**
- Live CPU, memory, storage, battery health, temperature state and network around the orb
- "How's my Mac?" is answered from a live reading, on device when possible
- Warnings for low battery, low storage, memory pressure and overheating
- Disk cleanup: finds large files, old downloads, duplicates, caches and developer data, shows what's safe, and asks before removing anything. Your files go to the Trash so they can be restored
- Folder tidying (Downloads, Desktop...) by kind, with one-step undo

**Models**
- Quick questions go to an on-device model (Apple Intelligence or Ollama): free, private, about a second
- Everything else goes to Gemini (lite / flash / pro, chosen per request), with fallback to lighter models on rate limits
- Claude is optional: used first when a key is set, and Gemini takes over automatically if it fails

## Install

Requires macOS 15 or later (Liquid Glass on macOS 26) and Xcode 26 or later to build.

```sh
./scripts/install.sh      # builds, signs, installs to /Applications and opens Jarvis
```

The first run walks you through the terms, your Gemini key (free from Google AI Studio), an optional Claude key, permissions and your voice. Chat subscriptions such as Gemini Plus or Claude Pro don't include API access, so keys are separate.

### Permissions that keep asking

macOS remembers permissions per code signature. `scripts/signing.sh` creates a local signing identity once, in its own keychain, and every build is signed with it, so permissions stick across rebuilds. `install.sh` also clears records left by older, differently signed builds. If a switch in System Settings looks on but Jarvis still asks, use **Settings → Safety → Repair permissions**.

## Security and privacy

- API keys live only in your Keychain, readable on this Mac while you're logged in; they're never logged or shown
- Speech is recognised on device; nothing leaves the Mac until you talk to Jarvis
- Terminal commands run under `sandbox-exec`: no network, no writes outside a scratch folder, no access to credential folders
- Text from web pages, mail, files and calendar invites is treated as data, never as instructions, and risky steps after reading it always ask first
- Sending, deleting, buying and entering passwords always ask for confirmation
- `scripts/check_secrets.sh` runs as a pre-commit hook and in CI, so keys and certificates can't be committed (`git config core.hooksPath .githooks` enables the hook in a fresh clone)

## Development

```sh
swift build
swift test
./scripts/bundle.sh       # build/Jarvis.app and a zip
```

- `Sources/JarvisCore` – models and routing, agents, tools, voice, Mac monitoring, cleanup
- `Sources/Jarvis` – SwiftUI app: glass HUD, floating ask bar, settings, onboarding

## Releases

Versions live in `VERSION` and `CHANGELOG.md`. `./scripts/release.sh 0.5.0` bumps the version, tags and pushes; GitHub Actions runs the tests and publishes the zipped app.

## Licence

MIT. Jarvis uses only Apple's system frameworks; see `THIRD_PARTY_NOTICES.md` for optional components you can add yourself.
