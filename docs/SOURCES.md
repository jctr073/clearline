# Technical sources checked

Checked during implementation on September 8–9, 2026. Current source pages informed APIs and capability choices; compiled SDK headers were also inspected for Swift names and availability. No SDK or source claims establish account access or actual host compatibility.

## OpenAI

- [GPT-4.1 mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini): non-reasoning text model with Responses and structured output support.
- [GPT-4.1](https://developers.openai.com/api/docs/models/gpt-4.1): non-reasoning text model; no adjustable effort.
- [GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4): supported efforts `none`, `low`, `medium`, `high`, `xhigh`, default `none`.
- [Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs): strict JSON Schema through Responses `text.format`; refusals/incomplete responses need handling.
- [Streaming responses](https://developers.openai.com/api/docs/guides/streaming-responses): SSE events and completed responses.
- [Agents overview](https://developers.openai.com/api/docs/guides/agents), [quickstart](https://developers.openai.com/api/docs/guides/agents/quickstart), [agent definitions](https://developers.openai.com/api/docs/guides/agents/define-agents), [running agents](https://developers.openai.com/api/docs/guides/agents/running-agents): official SDKs are Python and TypeScript. Clearline does not assume a native Swift Agents SDK.
- [API data controls](https://developers.openai.com/api/docs/guides/your-data): provider retention is account/feature dependent; `store: false` must not be described as zero retention.
- [Official Agents SDK usage implementation](https://github.com/openai/openai-agents-python/blob/main/docs/usage.md): usage includes cache-write token details. Live verification exposed an incompatible older Agents/OpenAI pair; the runtime now pins and tests Agents 0.22.1 with OpenAI 3.10.0, including real run-context construction.

## Apple

- [SwiftUI](https://developer.apple.com/swiftui/) and [AppKit](https://developer.apple.com/documentation/appkit): native app UI.
- [NSSpellChecker](https://developer.apple.com/documentation/appkit/nsspellchecker): asynchronous checking, per-document ignored words, and available languages. Xcode headers and live output confirmed this Mac advertises U.S. English as `en`.
- [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement): public Accessibility reading, querying, observing, and selected-text replacement.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions): explicit permission prompting.
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice): supported launch-at-login mechanism.
- [App Sandbox restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox): official Markdown text was fetched and confirms assistive Accessibility API use is incompatible with App Sandbox.
- [Developer ID](https://developer.apple.com/developer-id/) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): direct distribution, hardened runtime, signing, notarytool, and stapler requirements. This implementation has not completed that release process.
