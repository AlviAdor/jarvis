# Changelog

## 0.4.0
**Fixes**
- Permissions no longer get asked for again after every build. Builds are signed with a stable local identity, the installer clears records left by older builds, and Settings has a Repair permissions button
- Screen capture uses ScreenCaptureKit, leaves Jarvis's own windows out, and each system prompt is shown at most once per session
- Esc no longer depends on Input Monitoring, and Jarvis's own key presses can't trip it
- Much lower idle CPU: the window no longer re-lays itself out for every mic level, the hidden ask bar draws nothing, disk readings are cached, and the mic gate adapts to background noise

**New**
- Glass interface with no title bar: Liquid Glass on macOS 26, live telemetry ring around the orb, reticle, waveform, gauges with sparklines, a step timeline and session history
- Floating ask bar on the global shortcut, from any app: speak or type, the answer appears in place
- Mac care: live health report (CPU, memory, storage, battery health and cycles, temperature, network, busiest apps) and proactive warnings
- Disk cleanup (large files, old downloads, duplicates, caches, Xcode and simulator data, Homebrew and npm caches, Trash) with confirmation and Trash-first safety
- Folder organiser with undo
- Calendar, Reminders, Contacts, Notes, Messages, media and system controls, Shortcuts, Spotlight file search, reading PDFs and Word documents, web search and page reading, typing into the front app, changing settings by voice, a daily briefing
- Jobs can hand themselves over to screen control when they need it
- Voiceprint rebuilt on MFCC features and tested against real speech
- Onboarding: first-run guide with key setup, tests and links, terms of use, permissions and voice
- On-device answers through Apple Intelligence or Ollama, streamed and spoken sentence by sentence
- Gemini 3 model support with automatic selection of the newest models a key can use
- Secret scanning in a pre-commit hook and CI

## 0.2.0
- Always-on wake word ("Jarvis") with on-device speech recognition, gated by a cheap volume check
- Gemini as the main provider with lite / flash / pro tiers, automatic fallback to lighter models on rate limits, and Google Search for current questions
- Claude kept as an optional provider: used first when a key is set, with automatic fallback to Gemini on any failure
- Menu bar app with a floating overlay, launch at login, and a `jarvis://ask` / `jarvis://listen` URL scheme for Siri Shortcuts
- Tools: open apps and links, clipboard, memory, scheduled automations, timers, readable folders, Mail, sandboxed shell
- Shell commands run under sandbox-exec: no network, no writes outside a scratch folder, no access to credential folders
- Full settings window and unit tests

## 0.1.0
- First version: voice input, model routing, screen control loop
