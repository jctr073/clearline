# Clearline

A native Mac writing workspace with an AppKit editor, local writing checks, and optional OpenAI tools. SwiftUI supplies document navigation, suggestion cards, onboarding, settings, and proposal review. No account or network is needed for the editor.

**Current delivery:** runnable development application with verified offline editing, real OpenAI rewrites through both the native Responses client and official Agents SDK, and automated integration tests. Accessibility permission is granted; real external replacement verification remains pending. This is not a Developer ID signed, notarized public release. See [feature status](docs/FEATURES.md), [verification](docs/VERIFICATION.md), and [host compatibility](docs/COMPATIBILITY.md).

## Build and run

Prerequisites:

- macOS 14 or later; the actual test Mac runs macOS 26.6.2, Apple M3 Max, 36 GiB RAM.
- Swift 6.0+ toolchain and full Xcode. Actual build: Swift 6.3.3, Xcode 26.6 (17F113). Swift 5 language mode is explicit in the package; application state is main-actor isolated.
- No third-party Swift dependencies. Python is unnecessary for normal app use.

From the repository:

```sh
./scripts/build.sh
open dist/Clearline.app
./scripts/test.sh
```

For an optimized build:

```sh
./scripts/build.sh release
```

To build an optimized app and install it in `/Applications`:

```sh
./scripts/install.sh
open /Applications/Clearline.app
```

The installer verifies the development signature, stages the new app before replacing an existing Clearline installation, and requests `sudo` only if the destination directory needs it. Run it as your normal user. Quit any running Clearline instance before opening the installed copy. Documents, preferences, and Keychain credentials remain in their existing locations. For a debug build or a different existing Applications directory, use `./scripts/install.sh debug "$HOME/Applications"`.

The script builds the Swift package, creates `dist/Clearline.app`, draws the original application icon, generates bundle metadata from `Brand` in `Models.swift`, and signs with the single valid **Apple Development** identity in your login Keychain. The build fails if no unique identity is available; it never silently falls back to ad-hoc signing. Open `Package.swift` in Xcode for source navigation and debugging, or use `swift run Clearline` for editor development. Use the packaged app for Keychain, menu-bar, launch-at-login, and Accessibility testing: an unbundled executable has different OS identity behavior. Quit and reopen after a build to load the new executable.

### Consistent local signing

Use the same signing identity and app location for successive builds. By default, `build.sh` selects the single valid Apple Development signing identity on this Mac. If you have multiple identities, select one explicitly:

```sh
security find-identity -v -p codesigning
CLEARLINE_SIGN_IDENTITY="<certificate SHA-1 from the list>" ./scripts/build.sh
```

The same override works with `scripts/install.sh`. Keep using that identity for both debug and release builds. The identity consists of a certificate and its associated private key in Keychain; the build uses `codesign` without exporting the key. If macOS asks to let `codesign` use the signing key, authorize that access yourself. A sandbox may hide identities, so run the build with Keychain access when necessary.

After switching from an ad-hoc build, reauthorize the new app once for Keychain and Accessibility. For everyday use, install to `/Applications/Clearline.app` and open that copy consistently. Existing permission entries for the old signature may need to be removed and re-added. Stable signing prevents the identity from changing merely because the app was rebuilt; changes to signing identity, OS policy, or permission settings can still require authorization. See [Apple's code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

For an intentional disposable ad-hoc build, use `CLEARLINE_SIGN_IDENTITY=- ./scripts/build.sh`; permission prompts may recur after each rebuild. Apple Development signing is for local development and is not Developer ID distribution or notarization.

The build deliberately disables **SwiftPM's manifest sandbox**, not the macOS application security system. In a restricted agent environment, compiler cache warnings are harmless, but native spelling, Launch Services, and `iconutil` may require execution outside that agent sandbox. A sandboxed spelling test can fail despite an installed dictionary. Do not treat that result as a working offline service.

## Use the workspace

Create a document with **⌘N**, paste or type, and review actual macOS spelling and local-rule findings. Click a card to select its range. Accept a change, dismiss it for the current revision, or add an unfamiliar spelling to your personal dictionary. **Edit → Undo / Redo** reverses accepted changes. Safe batch acceptance is available only for non-overlapping mechanical local corrections; stylistic and AI rewrites require individual review.

- Rename with the editable document title. Search document titles and contents in the sidebar. Use a document's context menu to duplicate or delete it.
- Import/export, full-document copy, selected-text copy, and revision history are in the editor's **…** menu.
- **⌥⌘↓ / ⌥⌘↑** navigate suggestions. **⌘Return** accepts the selected suggestion; **⌥⌘Delete** dismisses it. Writing tools use **⇧⌘R**. The Writing menu also provides paragraph and full-document scopes.
- Markdown is edited as literal source. Formatting buttons insert Markdown syntax. Plain-text formatting buttons are disabled. RTF supports attributed bold, italic, headings, lists, and links; advanced typography/layout is not a fidelity promise.
- macOS keyboard input can still honor the user's double-space-to-period setting. Import/export does not perform this substitution.
- Pause stops analysis and invalidates cross-app capture; typing and document management remain available.

## OpenAI configuration

Open **Settings → OpenAI**. Read the cloud disclosure, then either enter your own key in the secure field or choose **Import from ~/.zshrc**. The importer scans only for literal OpenAI key assignments, prefers `OPENAI_API_KEY`, and never sources the file or evaluates substitutions. Ambiguous/nonliteral assignments are refused. It does not print the key. It stores a configured key in macOS Keychain with service `com.clearline.desktop.openai`, account `api-key`, accessible only on this unlocked device. Finder-launched apps read Keychain, not shell environment variables.

**Verified in this session after explicit user approval:** literal key import into Keychain, credential access after relaunch, account discovery of all three supported models, real native `gpt-4.1-mini` proposal review/application, and real Agents SDK `gpt-5.4`/`low` proposals. Model and effort persisted through relaunch. A cancelled regeneration left the source unchanged. No production AI result was simulated. Quota exhaustion and billing were not tested.

After saving a key, **Refresh models** checks `/v1/models` directly, bypassing the local HTTP cache. Settings and the writing panel show a short list of current writing models available to your account, newest first:

| Model | Reasoning effort |
| --- | --- |
| GPT-6 Astra | Low, Medium, High, Extra high, Max |
| GPT-5.6 Sol | None, Low, Medium, High, Extra high, Max |
| GPT-5.6 Terra | None, Low, Medium, High, Extra high, Max |
| GPT-5.6 Luna | None, Low, Medium, High, Extra high, Max |
| GPT-5.5 | None, Low, Medium, High, Extra high |

Reasoning settings follow the [Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), [Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna), and [GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5) API documentation. Extra high sends `xhigh`. Both the native client and optional Agents SDK use the selected effort. New installations default to Terra with Medium effort. Existing saved models remain selected, with a separate saved-model entry when outside the short list; unavailable selections are labeled. Previously empty or unsupported efforts normalize to the model's configured default on load, without changing the model.

Audio, image, coding variants, and dated snapshots are omitted from the short list. Account discovery is retained separately to check availability of existing saved choices. Legacy `gpt-4.1` and `gpt-4.1-mini` omit reasoning; `gpt-5.4` retains None through Extra high. Unrecognized saved models use API-default reasoning. Refresh does not generate text or run billable capability probes. Failed refreshes clear discovery. Model changes normalize unsupported effort visibly, and API errors never switch models. Defaults persist locally and can be overridden in the writing panel. Each request captures immutable model, effort, output limit, and timeout values.

**Settings → OpenAI → API usage** shows locally recorded responses with usage, input/output/total tokens, reported cached input and reasoning tokens, and a model breakdown. Choose Today, This month, or All recorded; day and month boundaries use UTC. Counts come from provider usage metadata in native terminal responses (including incomplete or invalid proposals when metadata arrives) and successful Agents SDK results. Cached input and reasoning tokens are subsets, not additional tokens. Stats persist in `api-usage.json`, containing only dates, model IDs, and aggregate counts across keys used on this Mac. Reset local stats clears these aggregates. Earlier usage, cancelled streams, disconnected requests, and failed SDK runs may be missing; this is not billing or a remaining-credit balance. The linked OpenAI usage dashboard provides account usage. No additional API requests are made to collect these stats.

Select text or choose a paragraph/document operation. Choose clarity, shortening, expansion, simplification, tone changes, a custom rewrite, drafting, summarization, notes-to-email/message/outline/document, missing-context review, or translation. Inspect original and proposed text, word-level changes, explanations, and heuristic fact-change warnings. Regenerate with follow-up instructions, copy, cancel, or accept. Protected-content and fact preservation are **not guaranteed**; suspicious changes require acknowledgement before acceptance. Malformed, incomplete, cancelled, and stale responses cannot edit the document.

The native client uses OpenAI's **Responses API**, streamed over HTTPS, with strict JSON Schema, `store: false`, no external tools, bounded payloads, a configurable timeout, and at most two retries for rate limits/transient server errors. The preview displays streaming progress; partial JSON never becomes an editable proposal. Automatic cloud checks are off by default. If enabled, they send the document after typing pauses, subject to the configured payload limit.

`store: false` is not a promise of zero provider retention. Review your account's [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data). Credentials, document bodies, and model outputs are not logged by Clearline.

### Optional official Agents SDK boundary

The desktop stays in Swift. An optional Python worker provides the official OpenAI **Agents SDK** `Agent`/`Runner` framework behind the same Swift `WritingProvider` protocol. It uses a private stdin/stdout pipe, not an HTTP listener. It receives the configured key only in memory over that pipe, disables tracing, has no file/browser tools or handoffs, enforces structured output, and exits after one operation. The native Responses client remains available without Python.

Use Python **3.10 or later** (macOS's bundled Python 3.9 is insufficient):

```sh
CLEARLINE_PYTHON=/absolute/path/to/python3.11 ./scripts/install-agent-runtime.sh
```

The default installation is `~/Library/Application Support/Clearline/AgentRuntime`. Enable **Use local OpenAI Agents SDK runtime** in settings. Development overrides `CLEARLINE_AGENT_RUNTIME` (installer) and `CLEARLINE_AGENT_PYTHON` (app process) are available; Finder does not inherit them. Use the default installation for Finder launches. Dependencies are pinned in `agent-service/requirements.txt` to the versions actually tested.

Run isolated SDK tests, without credentials:

```sh
"$HOME/Library/Application Support/Clearline/AgentRuntime/bin/python3" \
  -m unittest discover -s agent-service -v
```

SDK worker results are delivered on completion rather than streamed into the preview. Cancelling terminates the child process. The native provider supports live streaming progress. The tested pair is `openai-agents==0.22.1` with `openai==3.10.0`, using Python 3.12.14. Six SDK tests pass, including real SDK run-context construction; real model calls also succeeded. An earlier incompatible dependency pair was caught during live verification and replaced.

## Cross-app setup

Open **Settings → Cross-app**, enable selected-text assistance, then explicitly grant Clearline permission in **System Settings → Privacy & Security → Accessibility**. You can revoke it there at any time. Clearline never requests it merely to open the editor.

1. Under **App access**, click **Browse apps…**, select one or more installed apps (Command-click for individual apps or Shift-click for a range), then click **Allow selected apps**. All selected apps are added directly to Allowed apps, without another confirmation step. The native browser starts in Applications and can navigate to other folders. Clearline reads the app name and bundle identifier without launching it; lists show names and icons, with identifiers below. **Advanced: enter a bundle identifier** remains available for manual entry and blocking apps. Allowing a blocked app moves it to Allowed apps; blocking an allowed app moves it to Blocked apps. Unblocking removes access until you allow the app again. Only TextEdit is on the default allowlist; **this is not a compatibility claim**. Missing apps retain their identifiers so you can remove them.
2. Select text in that app, then invoke **⌥⌘Space** or **Assist selected text** in Clearline's menu-bar menu. Alternative shortcut keys are configurable; registration failures explain the menu fallback.
3. Review the captured passage in the native floating panel. Generate and inspect a proposal.
4. Choose **Replace selection**, **Copy**, or close the panel. Copy writes only when explicitly chosen; Clearline never reads or silently replaces the clipboard.

Before replacement, Clearline rechecks permission, pause state, the allow/block lists, source process, actual AX element equality, full field value, exact selection and selected text. It writes only `AXSelectedText`; there is no whole-field replacement fallback. Unsupported hosts get an explicit copy/paste explanation. Secure roles/subroles and their ancestor chain are excluded. The field must expose both selected text and full value for the safety check; large fields over 200,000 UTF-16 units are refused. Captured text stays in memory and is not saved as a document/history entry.

Source activation, relevant focus/value/selection changes, and supported window move/resize notifications invalidate the panel. It is a nonactivating floating `NSPanel`, clamped to the pointer's display. Selection geometry is queried where available; precise inline overlays are not shipped. Final validation is required even on hosts that omit change notifications. Host formatting and undo are **not universal**.

**Current verification:** Accessibility permission was granted with user authentication. No external host has been certified yet; physical shortcut and host replacement checks are still pending. The [compatibility matrix](docs/COMPATIBILITY.md) records actual installed versions and the unresolved checks. Continuous cross-app observation and anchored indicators are deferred until a real host passes the safety/geometry tests.

## Persistence, recovery, and deletion

Data lives at `~/Library/Application Support/Clearline`:

- `library.json`: versioned documents, stable IDs, monotonic revisions, selected document, and up to 50 snapshots per document.
- `library.backup.json`: previous known-good library; a damaged primary is preserved as `library.damaged-<id>.json` before recovery.
- `api-usage.json`: local daily API token aggregates and recording start date; no credentials, prompts, or outputs.
- `preferences.json`: goals, model/effort, dictionaries, terms, rule switches, explicitly supplied voice samples/profile, and app allow/block lists. **No keys.** Additive preference fields inherit defaults; invalid types fail visibly.

Autosave debounces for 250 ms and writes atomically on a storage actor. Normal quit flushes pending saves; a failed flush cancels quit. A crash can lose the last debounce interval. Recovery tests corrupt the primary and confirm restoration from backup. Library schema 1 rejects newer schemas without overwriting them. More complex future migrations must be explicit and backed up before writing.

For a manual backup, quit Clearline and copy the entire data folder (or use Time Machine). Restore while the app is closed. A document/history deletion updates automatic recovery copies and removes damaged-library copies, so deleted content is not retained there; separately managed/Time Machine backups remain your responsibility. Dictionary and voice controls delete those records. There is no telemetry or cloud sync; API usage aggregates stay on this Mac.

`CLEARLINE_DATA_DIR=/absolute/test/path` isolates local development data when launching from a terminal.

## Distribution

The chosen path is direct distribution with **Developer ID**, not the Mac App Store: Apple lists assistive Accessibility APIs among [functionality incompatible with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox). This app is not App-Sandbox enabled. It still depends on explicit macOS Accessibility permission and Keychain access.

The default local bundle uses Apple Development signing. Developer ID signing, hardened-runtime validation, notarization, stapling, and clean-machine Gatekeeper testing have **not** been performed. With your own signing identity and existing notary Keychain profile, the intended release steps are:

```sh
./scripts/build.sh release
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: YOUR IDENTITY" dist/Clearline.app
codesign --verify --deep --strict --verbose=2 dist/Clearline.app
ditto -c -k --keepParent dist/Clearline.app dist/Clearline.zip
xcrun notarytool submit dist/Clearline.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple dist/Clearline.app
spctl --assess --type execute --verbose=2 dist/Clearline.app
```

Recreate the ZIP after stapling. Test the hardened app, optional Python runtime, Keychain continuity, login registration, AX permission continuity, and host matrix before publishing. Do not bypass Gatekeeper to claim a successful distribution test. The separately installed SDK runtime is not bundled/signature-verified as a standalone redistributable dependency; a polished SDK-enabled installer remains release work. See [Apple's Developer ID guidance](https://developer.apple.com/developer-id/).

## Further documentation

- [Feature checklist](docs/FEATURES.md): phases and exact implemented/verified/blocked/deferred scope.
- [Architecture and decisions](docs/ARCHITECTURE.md): boundaries, invariants, privacy, and tradeoffs.
- [Actual verification results](docs/VERIFICATION.md): automated and manual evidence, machine and timings.
- [Compatibility matrix and manual checks](docs/COMPATIBILITY.md): no mock test is a host certification.
- [Technical sources](docs/SOURCES.md): official documentation checked during implementation.
