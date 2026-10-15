# Changelog

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
