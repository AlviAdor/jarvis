# Jarvis

A voice-first assistant for macOS. Say "Jarvis", or press a shortcut from any app, and ask. It answers out loud, and it can operate your Mac while you watch: your apps, files, calendar, messages, music, settings, disk space and screen.

## What it can do

**Talk and listen**
- Always-on wake word ("Jarvis"), recognised on this Mac. While idle it only checks the mic level, and it adapts to the room's background noise
- Answers are spoken (Mac voices, your Personal Voice, or Gemini studio voices) and shown as short, copiable text
- Optional voice match: learns your voice from five phrases and ignores other people and the TV
- Patient listening: if you pause to find a word, say "um" or repeat yourself, it waits for you to finish, and learns how you usually pause
- Hears your words: a language model built on your Mac knows your name, places and apps, common mishearings are fixed in context, and it learns from the requests you correct
- Talk over it to interrupt; replies start speaking at the first sentence

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
- Live CPU, memory, storage, battery health, temperature state and network around the orb (optional, off by default)
- "How's my Mac?" is answered from a live reading, on device when possible
- Warnings for low battery, low storage, memory pressure and overheating
- Disk cleanup: finds large files, old downloads, duplicates, caches and developer data, shows what's safe, and asks before removing anything. Your files go to the Trash so they can be restored
- Folder tidying (Downloads, Desktop...) by kind, with one-step undo

**Chat like the big AI apps**
- Attach images, PDFs, documents, code, audio and video (drag, paste, or the + menu), or a screenshot of your screen
- Search, Think and Screen switches, a model picker, and formatted answers with code blocks
- Read aloud, copy, try again, edit and share any answer

**Any language**
- Talk or type in almost any language; Jarvis understands it (through Gemini) and answers and speaks in the same language

**Effort and usage**
- Effort from Low to Max controls thinking depth, model strength and answer length; the usage saver stretches the free Gemini allowance; when the cloud isn't available, the local model answers

**Works your Mac and your work**
- Operates apps through their real buttons, fields and menus, AppleScript, files and the browser, and Gemini's computer use for screen tasks
- Git, tests, linting, API calls, SQLite, documents (proposals, contracts, reports), Mail drafts, RSS feeds, Spotify, audio devices and focus noise
- Connectors for HubSpot, Notion, Airtable, Slack, GitHub and Postgres
- Drives other AI assistants (ChatGPT, Claude, Gemini, Grok, Perplexity, Copilot): it writes a proper prompt from your words, types it into their message box and can read the reply back

**Remembers you**
- Keeps the conversation across restarts, so follow-ups like "and tomorrow?" just work
- Gets to know you by talking during setup: it asks out loud, you answer, and it learns your voice from those answers. It keeps learning from what you mention, all stored on this Mac
- Adaptive colour: cyan for light work, shifting to red as work gets heavy

**Models**
- Quick questions go to an on-device model, Ollama (preferred when running) or Apple Intelligence: free, private, about a second. Ollama needs no API key: install it and download a model from Settings, Models
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
