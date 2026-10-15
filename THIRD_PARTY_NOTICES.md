# Third-party notices

Jarvis contains no third-party source code or libraries. It is built only on Apple's system frameworks (SwiftUI, AppKit, Speech, AVFoundation, ScreenCaptureKit, Vision, EventKit, Contacts, PDFKit, CoreWLAN, IOKit, Accelerate, CryptoKit and, where available, FoundationModels).

The app icon is drawn by `scripts/make_icon.swift`, and the voiceprint, routing, cleanup and agent code are original to this project, under the MIT licence in `LICENSE`.

## Optional components you install yourself

None of these ship with Jarvis. They're used only if you install and enable them, and each is governed by its own licence:

| Component | What Jarvis uses it for | Licence |
| --- | --- | --- |
| [Ollama](https://github.com/ollama/ollama) | On-device answers for quick questions | MIT (models have their own licences) |
| [MCP filesystem and memory servers](https://github.com/modelcontextprotocol/servers) | Tool server presets | MIT |
| [mcp-server-fetch, mcp-server-time](https://github.com/modelcontextprotocol/servers) | Tool server presets | MIT |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | Browser tool server preset | Apache 2.0 |

## Online services

Requests you send to Google Gemini or Anthropic Claude are covered by their terms, which you accept during setup:

- Gemini API Additional Terms of Service and the Generative AI Prohibited Use Policy
- Anthropic Usage Policy and terms of service
