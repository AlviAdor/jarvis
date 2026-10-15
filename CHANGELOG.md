# Changelog

## 0.11.0
**Operating your Mac smartly**
- Jarvis works apps through their real controls (Accessibility): it reads the front window's buttons, fields and menus, presses and fills them by name, chooses menu items like "File > Export as PDF…", switches apps and minimises, closes or hides windows, all without screenshots
- AppleScript for almost any app, shown as it runs; scripts that delete, send, type keystrokes or run shell commands ask first (configurable)
- Moves, copies, renames, zips and unzips your files and makes folders, inside your home folder and never overwriting
- Knows the page you're on in Safari, Chrome, Arc, Edge or Brave, your open tabs, and can read the page for "summarise this"
- Screen tasks use Gemini's built-in computer use (click, type, scroll, drag, keys on a 0-999 grid, with Gemini's own confirmations), falling back to the screenshot method
- Requests to open, click, close or switch go to these controls first; only things that need eyes start with a screenshot

**Work and developer tools**
- Git status, log, branches and diffs, commits with messages written from the diff, pushes, GitHub pull request status, and running a project's tests, formatter or linter
- An API client for any endpoint (including localhost), SQLite queries (changes ask first), and searching inside your code and documents
- Proposals, contracts, NDAs, status updates, case studies and cover letters saved as Word, RTF or Markdown documents in Documents/Jarvis, and Mail drafts with attachments
- RSS and Atom feeds for job boards, blogs and news; pair with automations for a daily job digest

**Music and sound**
- Spotify: what's playing, play a link, pause, skip, shuffle, repeat, volume and search
- Switch speakers or microphone, and play white, pink or brown focus noise generated on the Mac

**Connectors**
- Ready-made MIT-licensed connectors for HubSpot, Notion, Airtable, Slack, GitHub and Postgres; access tokens are kept in the Keychain
- One click installs Node.js (official LTS, checksum-verified, no admin rights) so connectors can run
- Only the tool groups that matter for a request are sent, keeping requests small and quick

## 0.10.0
- Any language: speech that isn't confident English goes to Gemini, which understands most languages, and Jarvis answers in the language you used; typed messages work the same way
- Speaks each language properly: replies use a Mac voice for that language, or Gemini's multilingual voice when none is installed, with a one-click way to get the missing voice
- Helps with anything: what Jarvis knows about you personalises answers but never limits them; real questions (reasoning, advice, writing, anything long) go to a stronger model instead of the quickest one
- Effort setting (Low, Balanced, High, Max) for thinking depth, model strength, answer length and steps, also in the composer's model menu
- Usage saver: answers on this Mac whenever possible, Lite models only, the Mac voice, no background requests and shorter context, to stretch the free allowance
- Works without the cloud: when Gemini is out of requests, offline or not set up, the local model answers instead of an error
- Faster: answers appear as Gemini writes them, web answers start speaking at the first sentence, the connection is warmed while you talk, finished sentences end sooner, and long earlier answers are trimmed before being sent again
- Gemini voice requests now count in today's usage
- New app icon: a particle globe with a tilted orbital ring in a glass squircle; the orb's ring in the app matches it

## 0.9.0
- Calmer orb: heavier work adds a gentle lift to the pace instead of a rush, particles swell softly rather than jump, every change eases over a few seconds, and it runs at 30 frames a second at rest for smoother motion
- Voice match no longer locks you out: if there's too little audio to judge, the request goes through; the voiceprint keeps all your samples and compares against the closest ones, sets its threshold from how consistent your own voice is, and keeps learning from confident matches and push-to-talk requests
- "It was me": when a request is turned away, one click teaches Jarvis that sample and runs the request
- Quieter speech is heard: the mic level adapts to the room, recognition is told to expect "Jarvis" and your name, and near misses like "Jervis" or "Javis" still wake it
- Say just "Jarvis" and it answers by name ("Yes, Alvi?"); it greets you when it starts; short phrases in the Gemini voice are kept so they play instantly
- No routine checks on your Mac: only one light reading every ten minutes, and a quiet notification only when the Mac has been under extreme strain for a long stretch (memory or heat for 15 to 20 minutes, a nearly full disk, or a battery about to die); live readings for the colour come only from the optional live readings
- Faster when Gemini is busy: a model at its per-minute limit is skipped at once instead of waited on

## 0.8.2
- The particle sphere follows the workload: it spins up to about four and a half times faster as work gets heavier, particles jump off the surface in bursts that grow with the load, and the ring speeds up, all in step with the colour shift from cyan to red
- The same applies when the Mac itself is under strain; everything settles back smoothly when Jarvis is done

## 0.8.1
- Far fewer "usage limit" stops: each tier now rotates through every model the key has, and everyday chat and web searches step up to Flash when the Lite models run out
- Web searches start on Lite models, which have the largest free allowance, leaving Flash for screen work
- The Gemini studio voice knows when it's out of free requests: it tries the key's other voice models, otherwise speaks with the Mac voice at once, and says so once with a button to switch to the Mac voice for good
- Settings, Models shows Google's own message for each model that's resting
- A model the key can't use (access refused) no longer stops the request; the next model is tried

## 0.8.0
- Notifications are clickable and have actions: reply to Jarvis right from the notification, copy or read an answer aloud, snooze a timer, and for Mac warnings jump straight to "Free up space", "What's using memory?", "What's draining the battery?" or "What's heating it up?"
- Notifications show even while Jarvis is in front, and automations post their answer as a notification you can reply to
- The floating bubble is clickable: open Jarvis, stop, read aloud, copy, ask something else or close; it stays put while the pointer is over it, and stays click-through while Jarvis is working on the screen
- In-window notices can carry an action, such as Undo after Jarvis notes something new about you

## 0.7.2
- Start a freshly installed Ollama by its location, before macOS has registered it by name

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
