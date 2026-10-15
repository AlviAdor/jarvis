# Jarvis

A voice-first assistant for macOS. Talk to it, and it answers or operates your Mac with the real mouse and keyboard while you watch.

## Features

- Voice in and out, on-device (Speech framework and AVSpeechSynthesizer)
- Auto model routing between Gemini and Claude to keep cost low; or pick a model yourself
- Screen control loop: screenshot, decide, move the cursor, click, type
- Press Esc at any time to stop
- Confirmation before sending, deleting, buying or entering credentials
- Monthly and per-task spending limits
- API keys kept in the macOS Keychain

## Build

Requires macOS 14+ and Xcode 16+ (Swift 5.9 or later).

```sh
swift build
swift run Jarvis
```

For a proper app bundle (recommended, so permissions persist):

```sh
./scripts/bundle.sh
open build/Jarvis.app
```

## Setup

1. Open Settings and add a Gemini API key (free tier from Google AI Studio) and/or a Claude API key (console.anthropic.com).
2. Grant Microphone, Speech Recognition, Accessibility, Screen Recording and Input Monitoring when prompted (System Settings → Privacy & Security).
3. Press the mic and speak.

Chat subscriptions such as Claude Pro or Gemini Plus do not include API access, so keys are needed.

## Layout

- `Sources/JarvisCore` – router, API clients, screen and input control, voice
- `Sources/Jarvis` – SwiftUI app, HUD and settings

## Status

Early version. Email handling and scheduled automations are not built yet.
