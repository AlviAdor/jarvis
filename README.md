# Jarvis

A voice-first assistant for macOS. Talk to it, and it answers or operates your Mac with the real mouse and keyboard while you watch.

## Features

- Always-on wake word ("Jarvis"), recognized on-device; idle cost is a volume check
- Gemini lite / flash / pro with automatic routing, fallback to lighter models on rate limits, and Google Search for current questions
- Optional Claude: used first when a key is set, and Gemini takes over automatically if it fails
- Screen control: screenshot, decide, move the real cursor, click, type. Esc stops it at any time
- Tools: open apps and links, clipboard, memory, scheduled automations, timers, file reading in chosen folders, Mail, sandboxed shell
- Shell runs under sandbox-exec with no network and no writes outside a scratch folder
- Confirmation before sending, deleting, buying or entering credentials
- Menu bar app with a floating overlay, optional launch at login
- Siri: make a Shortcut named "Ask Jarvis" that opens `jarvis://listen` (or `jarvis://ask?q=...`)

## Build

Requires macOS 15+ and Xcode 16+.

```sh
swift build
swift test
./scripts/bundle.sh
open build/Jarvis.app
```

## Setup

1. Open Settings and add a Gemini API key (free tier from Google AI Studio). A Claude key is optional.
2. Grant Microphone, Speech Recognition, Accessibility, Screen Recording and Input Monitoring when prompted (System Settings, Privacy and Security).
3. Say "Jarvis, what's the weather?" or press Talk now in the menu bar.

Chat subscriptions such as Claude Pro or Gemini Plus do not include API access, so keys are needed.

## Releases

Versions live in `VERSION` and `CHANGELOG.md`. `./scripts/release.sh 0.3.0` bumps the version, tags `v0.3.0` and pushes; GitHub Actions then runs the tests and publishes `Jarvis-0.3.0.zip` as a release.

## Layout

- `Sources/JarvisCore` – router, API clients, screen and input control, voice
- `Sources/Jarvis` – SwiftUI app, HUD and settings

## Status

Early version. Gemini and Claude calls have not been exercised against live keys yet.
