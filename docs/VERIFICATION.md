# Actual verification record

Updated September 9, 2026. “Implemented” is not interchangeable with “verified.”

## Machine and tools

- Apple M3 Max, 38,654,705,664 bytes RAM (36 GiB).
- macOS 26.6.2, build 25G83, Apple Silicon.
- Xcode 26.6, build 17F113; Apple Swift 6.3.3.
- Package deployment target macOS 14.0; no macOS 14 or Intel machine was tested.
- Optional SDK tests: Python 3.12.14, `openai-agents==0.22.1`, `openai==3.10.0`, installed in the app’s default Application Support isolated environment. System Python 3.9 was rejected as insufficient; installer now enforces Python ≥3.10.

## Automated execution

`./scripts/test.sh` was actually executed with access to native macOS services. Original recorded suite: **50 tests, 0 failures, 0 skips**, 3.604 seconds. The build-sandbox-only attempt failed the native spelling service because OS service access was restricted; it is not the reported passing run.

**Follow-up validation (2026-09-09):** the current Swift suite passed **74 tests with 0 failures**, including read-only selection classification, refusal of direct replacement for read-only captures, bounded Unicode inputs, workspace append, destination validation, rich-text preservation, and document-model synchronization after Undo and Redo. The installed SDK runtime also passed **9 Python tests** without network calls. A release build was signed, verified, installed in `/Applications/Clearline.app`, and relaunched. VS Code 1.135.0 exposed selected README preview text through the UI automation tool and was added to the allowed-app list with user approval. The automation could not trigger Clearline's global shortcut, so end-to-end VS Code capture, generation, and append remain pending a physical shortcut check; this is not a host compatibility certification.

Covered behaviors include:

- Valid edits, revision advancement, stale result rejection, mismatched originals, negative/out-of-bounds/overflowing ranges, overlapping and duplicate edits, batch classification, descending application, and safe insertion.
- Surrogate pairs, ZWJ family emoji, combining marks, Japanese, Hebrew, Arabic, and multiline range edits; chunk ownership reconstructs the full Unicode source.
- Diff reconstruction of both original and proposed text.
- Real local wordiness, spacing, repetition, disabled categories and individual rules, preferred terms, protected code/quotes, non-English gating, and fact-change warnings.
- Document/settings round trip, additive preference migration, corrupted-primary recovery, unknown future schema refusal, and deletion purging recovery copies.
- Actual NSSpellChecker misspelling detection, native NSTextView suggestion undo/redo, single-group batch undo, and attributed bold undo.
- Actual RTF and Office Open XML export/import of synthetic Unicode text with a bold run. This does not verify tables, tracked changes, comments, images, attachments, or layout fidelity.
- Account model filtering, documented reasoning normalization, wire-level omission/inclusion, captured configuration, completed structured responses, malformed/refused/incomplete results, invalid AI ranges, payload limits, authentication failures, interrupted streams, cancellation, timeouts, and exactly three attempts on persistent transient server errors. Network behavior uses a test-only URLProtocol, not real account credentials.
- A late AISession proposal attempting to apply after the source revision advances leaves the newer writing unchanged.
- Disabled/paused/permission-denied cross-app guards, without modifying macOS permissions. These are not real host replacement tests.

`python -m unittest discover -s agent-service -v` actually ran **6 tests, all passed**, after the dependency repair described below, using the installed official SDK. Tests inspect the real agent model/settings/output schema while replacing the SDK runner's network result inside tests; they verify reasoning, no tools, no stored state, timeout, invalid model/effort, and safe error output. No fixture is displayed by the production app and no key was used by the automated suite. The new regression test constructs the actual SDK run context without mocking Runner.

Local command transcripts are in ignored `artifacts/*.log` files: `tests-native.log`, `agent-tests.log`, `build-release.log`, and `clean-build.log`. The final source has no external Swift package dependencies. A fresh scratch-directory release build completed successfully in 14.19 seconds, separately from incremental builds. `codesign --verify --deep --strict` reports the packaged app valid on disk and satisfying its designated requirement; `plutil -lint` passes. Those original checks verified an ad-hoc local signature, not Developer ID signing/notarization.

**Local signing update (2026-09-09):** `scripts/build.sh` now selects the single valid Apple Development identity, supports an explicit `CLEARLINE_SIGN_IDENTITY`, and refuses silent ad-hoc fallback. The packaged Clearline app was signed with the existing Jesse Carter Apple Development identity and passed `codesign --verify --deep --strict`. A temporary copy with changed bundle-version metadata was signed with the same identity: its code hash changed while its designated requirement remained identical. This verifies stable code identity across content changes. Keychain and Accessibility permission continuity after the initial reauthorization still requires a user-level check; this is not Developer ID distribution or notarization.

## Performance measurements

Synthetic 10,000-word text: 1,000 repetitions of `Clear writing gives every reader more time to think deeply.` AppKit text layout was forced, 20 sequential insertions were measured on the main actor, and native asynchronous spelling was timed. Latest debug-test observations:

| Operation | Observed time |
| --- | --- |
| Local rules including protected-name detection, background worker | 62 ms |
| Initial native text layout | 12 ms |
| Slowest of 20 NSTextView insertions | 26 ms |
| Asynchronous native spelling for the full text | 212 ms |

An earlier cold run measured an 82 ms insertion; later runs ranged roughly 23–30 ms for the slowest insertion. These are actual timings, **not** a claim of stall-free typing. The test is not a full interactive IME/dictation session and does not measure all SwiftUI autosave/highlight work or OS scheduling. Further Instruments/interactive profiling is required before advertising a responsiveness target for all 10,000-word documents.

## Native UI observations

Actually observed in the running app:

- Native split workspace, document list, editor, suggestion cards, settings navigation, and Accessibility labels.
- Create and rename a separate synthetic `Clearline verification` document, type text, see real local clarity and native spelling suggestions, and see affected text underlined.
- Accept the misspelling correction; accept a clarity correction; use **Edit → Undo** to restore the original clarity phrase. A disabled default SwiftUI Undo menu was found and fixed with explicit native editor routing. Native undo/redo also passes automated tests.
- Reopen the saved library after quitting/relaunching. Existing user writing was preserved.
- Dark appearance inspected. Initial low-contrast accent text was improved in the app's dynamic palette.
- Provider setup and its missing-key/model-unavailable state inspected. The secure field remains empty; no key is visible in screenshots.
- Cross-app settings show **Accessibility permission is not currently granted**. The editor remains usable in that state.

Actual screenshots: [editor and suggestion review](../artifacts/editor-dark.png), [writing settings](../artifacts/settings.png), [OpenAI setup](../artifacts/openai-settings.png), [unconfigured writing panel](../artifacts/writing-tools-unconfigured.png), and [cross-app permission state](../artifacts/cross-app-permission.png). These capture the running native app, not mockups or generated images. The unconfigured panel contains no AI proposal. The permission screenshot is settings, not a successful host capture. A real cross-app review screenshot is still blocked on permission. After capturing settings, the user's document was restored to view without changing its text.

## Explicitly not verified

- Exhausted real billing quotas, server-side cancellation, all model/effort combinations, or broad linguistic quality. Successful live native and SDK requests are recorded below.
- Any external host's selection capture, selected-text replacement, formatting, undo, focus, secure-field, or stale-selection behavior. Permission was granted with user authentication, but host verification is still ongoing. See the completed-as-status [host matrix](COMPATIBILITY.md); no cells have been guessed as passing.
- Full English grammar evaluation, UK-vs-US corpus, or multilingual AI quality parity.
- Full keyboard-only and VoiceOver navigation; real IME composition, dictation, multiple displays, launch at login/reboot.
- End-to-end import/export panel workflows or complex DOCX/RTF fidelity.
- Continuous external focused-field observation or anchored indicators (not shipped).
- Developer ID signing, hardened-runtime/SDK integration, notarization, stapling, Gatekeeper distribution test, App Store review, macOS 14 runtime, or Intel build/runtime.

## Remaining manual checklist

- [x] Launch packaged native app on the documented Mac.
- [x] Create, rename, type, inspect real suggestions, accept, undo, and reopen saved text.
- [x] Work locally with no OpenAI key and no Accessibility permission.
- [x] Run deterministic edit/provider/persistence/SDK tests and native spelling/format/undo tests.
- [ ] Search, duplicate, dismiss, dictionary add/remove, and delete through the UI; verify recovery copies after deletion using only disposable data.
- [ ] Import/export UTF-8 text and Markdown through panels; verify byte-identical Markdown. Check declared RTF/DOCX conversion loss warnings.
- [ ] Restore and delete history via UI; verify saved revision behavior after relaunch.
- [ ] Light-mode screenshot, resize/minimum-size, keyboard-only controls and VoiceOver labels/actions.
- [ ] Input methods: marked composition, combining characters, dictated text, emoji and right-to-left selection changes.
- [x] Approve credential import, connect the account, refresh supported models, persist model/effort, send synthetic native and SDK requests, and inspect/apply/cancel a real proposal.
- [ ] Approve/grant Accessibility, run every host test in COMPATIBILITY.md, and capture the actual floating panel.
- [ ] Launch-at-login registration/revocation and actual login test; multi-display panel behavior.
- [ ] Clean-Mac signed/notarized release and minimum-macOS/Intel verification.

## Live verification after explicit approval

The user explicitly approved Keychain import, small synthetic API requests, and Accessibility permission. The key was imported through the app's existing control without printing it. An initial read from the still-running older app failed with Keychain status -25293; after relaunching the packaged build, Keychain retrieval and account model discovery succeeded. All three catalog models appeared. No credential was placed in source, logs, screenshots, command arguments, or documents.

Actually observed:

- The native Responses provider returned a structured `gpt-4.1-mini` clarity proposal for the separate synthetic **Clearline verification** document. The actual diff and warnings were inspected, acknowledged, and applied. The editor showed the proposed text and preserved the rest of the document.
- Defaults were changed to `gpt-5.4`, effort `low`, and the optional SDK provider. After quitting/relaunching, the action panel retained those values, and the prior applied text remained saved.
- The first SDK attempt failed before HTTP because Agents 0.8.4 constructed OpenAI 2.48.0 usage types without a required `cache_write_tokens` field. Mocked Runner tests did not catch this. The runtime and requirements now use the compatible published pair Agents 0.22.1/OpenAI 3.10.0, and a sixth regression test constructs the real SDK run context. All six tests pass (0.726 seconds in the first repaired run).
- With the repaired default Application Support runtime, the packaged app returned real SDK proposals for `gpt-5.4`/`low`. A follow-up regeneration also returned a real proposal. Starting another regeneration and immediately closing the panel left the source document unchanged.
- The user completed macOS Touch ID/password authentication; System Settings then visibly showed Clearline Accessibility **on**. A TextEdit test document was created with a Unicode-containing synthetic sentence and a precise selected subrange. Automation-generated shortcut events have not established real global shortcut delivery; physical-key verification is pending. A menu-bar UI tool lookup timed out. These tool attempts do not establish a passing or failing host replacement result.

Actual new screenshots: [native live response](../artifacts/openai-live-review.png) and [SDK live response with model/effort](../artifacts/sdk-live-review.png). Both show production responses, not fixtures. The model can still produce awkward wording or inaccurate explanations; this run does not certify writing quality or fact preservation.

## Pre-publication rerun

Before the initial GitHub push on September 9, the native suite passed again: 50 tests, zero failures, 3.745 seconds. The repaired SDK suite passed all six tests in 1.005 seconds. The native performance sample measured 60 ms for local rules, 12 ms initial layout, 31 ms slowest insertion, and 203 ms asynchronous spelling. No new live API requests were needed for this rerun. A credential-pattern scan of all 37 publishable text files found no matching secrets; generated binaries, runtime environments, and logs remain excluded by `.gitignore`.


### Dynamic model discovery — September 9, 2026

Removed the three-model allowlist in both native and Agents SDK request paths. A read-only `/v1/models` request using the existing environment credential returned 125 unique IDs, including 122 outside the former catalog. This checks discovery only, not writing compatibility or the app’s Keychain credential. No generation probes were sent.

All 53 Swift tests and 7 Python SDK tests passed. Regression coverage exercises the model-list HTTP endpoint, cache bypass, no generation during discovery, new IDs, deduplication, default reasoning on the wire, preserved known settings, and failure without fallback models. The Swift suite required running outside the agent sandbox for macOS spelling services.


### Local API usage stats — September 9, 2026

All 60 Swift tests and 8 Agents SDK tests passed after adding usage stats. New deterministic coverage verifies UTC day/month boundaries, model aggregation, cached/reasoning subsets, missing and invalid metadata, concurrent writes, relaunch persistence, reset, corrupt-file preservation, and future-schema rejection. Transport fixtures verify that native terminal usage is captured before invalid/incomplete proposal handling and that generated text cannot spoof usage. The SDK fixture uses the installed SDK’s real usage types and verifies separate metadata in the worker envelope. No billable live generation was performed for this feature; earlier usage cannot be backfilled.
