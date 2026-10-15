# Changelog

## 0.7.1
- Talk over Jarvis to stop it: it listens while speaking, learns how its own voice sounds in the mic, and stops as soon as you speak; what you say becomes the next request (mid-task, it only goes quiet)
- More time to finish a sentence: the default pause is longer, and Jarvis waits longer again when a sentence trails off ("…and", "because…")
- Installing Ollama now downloads the official app (native to Apple silicon) and checks it's signed and notarised by Ollama's developer before installing; Homebrew isn't used

## 0.7.0
- Attachments: add images, PDFs, documents, code, audio and short videos with the + menu, by dragging them onto the window, or by pasting an image with ⌘V; a screenshot of the screen can be attached too
- Composer like other AI apps: Search, Think and Screen switches, a model picker, and send, talk or stop in one button
- Answers show formatting and code blocks with copy, and can be read aloud, copied, tried again, edited or shared
- Particle sphere orb drawn on the GPU, with its own tilted orbital ring; the frame rate follows what Jarvis is doing and stops while hidden
- Cleaner main window: status at the top, the orb, the answer, and the composer; earlier answers open from the clock button
- Gemini free tier: Jarvis reads why a request was refused (per minute, per day, or not in the free tier), waits only as long as Google asks, rests that model and switches to another one, and explains in plain words when everything is used up; Settings, Models shows which models are resting
- No request is spent on sorting questions any more, which leaves more of the free allowance for answers
- The window sizes itself for setup and for the main view, within the screen

## 0.6.0
- Setup is now a conversation: Jarvis asks its questions out loud, you answer by voice (or type), and it fills in your profile from what you say
- The same answers teach Jarvis your voice, so the voiceprint comes from the person actually setting it up; "Only respond to my voice" switches on when it has enough
- Answers are understood on the spot and tidied up by Gemini at the end, which also notes lasting facts; everything stays editable in Settings, Memory
- "Talk with Jarvis again" in Settings reruns the conversation

## 0.5.0
- Memory: the conversation is kept across restarts, follow-ups like "and tomorrow?" continue the last topic, and every model (including the on-device one) now gets the conversation and what Jarvis knows about you
- Learns about you: an "About you" step in setup and in Settings, plus quiet learning of lasting facts you mention (never passwords or card numbers)
- Voice training during setup; once Jarvis has learned your voice, "Only respond to my voice" switches on
- New nucleus orb: glowing core, electrons on three tilted orbits and a particle cloud, all on the GPU
- Adaptive colour: cyan for light work shifting to red for heavy work (screen control, deep thinking, or a Mac under strain); both colours customisable, or keep one fixed colour
- The window's glass now meets macOS's own rounded corners exactly, with no transparent wedges
- Live Mac readings are off by default; turn them on in Settings
- Ollama: preferred automatically when running; install, start and download models from Settings with a progress bar; reasoning models skip their hidden thinking for faster replies

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
