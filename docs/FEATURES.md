# Feature checklist against the requested scope

Status meanings: **V** = implemented and the stated behavior was actually verified; **I** = implemented/compiled, with specific manual or live verification still pending; **P** = partial support with limits stated; **B** = verification/action blocked by an external prerequisite; **D** = not implemented yet, with the remaining work identified. A checked phase is not a claim that every possible host/language/format is certified.

## Phase 1 — offline native release foundation

| Requirement | Status | Evidence or limit |
| --- | --- | --- |
| Swift native source and reproducible build | V | Swift package; debug and optimized app builds on the documented Mac/Xcode configuration |
| Centralized Clearline branding and original identity | V | `Brand` constants drive app strings and generated bundle metadata; original code-drawn icon, ink/mint workspace |
| SwiftUI shell, document navigation, settings, suggestion cards | V | Actual running native window inspected through Accessibility and screenshot |
| AppKit text editor, precise ranges, native undo | V | NSTextView, grouped edits, actual accept and Edit → Undo; native undo/redo tests |
| New, rename, search, duplicate, delete, reopen documents | P | Create, rename, reopen verified live; search/duplicate/delete implemented, persistence/deletion verified in tests; remaining UI paths need checklist run |
| Local persistence, autosave, crash recovery | V/P | Atomic store/recovery/deletion tests pass; existing documents reopened; last 250 ms may be lost on crash, OS process-kill recovery not manually tested |
| Plain text and Markdown import/export | I | UTF-8 source-preserving read/write, 20 MB import limit; end-to-end file-panel round trip pending |
| Markdown headings/bold/italic/lists/links | I | Source syntax insertion; original Markdown is never rendered/re-serialized |
| Real native spelling without an API key | V | NSSpellChecker integration test and live misspelling card; `en_US` → Apple's `en` mapping verified |
| Native grammar/punctuation where supported | P | Asynchronous grammar results and details parsed; no universal language coverage claim; grammar corpus validation pending |
| Capitalization, repeated words, spacing | V/P | English “I”, consecutive repeated-word and space rules; unit tests for repetition/spacing; broader capitalization relies on native engine |
| Consistency, preferred/discouraged terms | V | Term replacements and rule disabling tested; literal terminology settings stored locally |
| Wordiness/redundant phrases | V | Real local optional style rules; live clarity card and acceptance |
| Passive voice | I | Opt-in conservative pattern, explanatory advice, no automatic meaning-changing rewrite |
| Awkward phrasing, sentence alternatives, contextual vocabulary | B | Implemented OpenAI operations; actual clarity outputs verified; broad quality/capability evaluation remains pending |
| Optional advice clearly separated from errors | V | Card labels, explanations, categories, optional flag and batch exclusions |
| Highlight ranges, matching cards, individual accept/dismiss | V/P | Highlights/accept verified live, dismiss implemented; stale/range protections covered by tests |
| Keyboard issue navigation, acceptance, dismissal | I | Commands and shortcuts implemented; full keyboard-only manual pass pending |
| Safe batch mechanical acceptance | V | Non-overlap/preflight/reverse-order application; single native undo group verified |
| Remove stale findings; deduplicate overlaps | V | Revision/generation checks and deterministic overlap tests |
| Personal dictionary and per-category/per-rule controls | V/P | Persistence, default migration, rule disabling tested; native dictionary integration implemented; complete UI add/remove pass pending |
| IME/dictation handling | P | Marked-text analysis suspension and commit handling implemented; real IME and dictation sessions not yet exercised |
| Counts and reading time | V | Unicode/count tests and actual UI values; reading estimate uses 225 words/minute |
| Readability and issue summary | P | Average sentence length and category counts only; no validated readability score or arbitrary quality score |
| Light/dark, resizing, readable size, VoiceOver labels | P | Native dynamic colors, split views, size slider and AX labels; dark screenshot inspected; full VoiceOver, light-mode, multi-display and resizing pass pending |
| Menu bar: open/new/rewrite/pause/settings/quit | I | Real MenuBarExtra compiled; all actions wired; menu-bar manual pass pending |
| First-run explanation of local/cloud/AX modes | I | Native onboarding implemented; first-run persistence flag, no automatic permission prompt |
| Checking/ready/paused/unavailable/offline/error states | V/P | Ready/checking/spelling-unavailable observed live; failure mappings/cancellation tests; offline AI requires live account verification |
| Editor usable without AX permission | V | Live editor used with Accessibility explicitly shown as not granted |
| Launch at login | I | SMAppService registration/unregistration and explanatory errors; actual login/reboot not tested |

## Phase 2 — OpenAI and writing workflows

| Requirement | Status | Evidence or limit |
| --- | --- | --- |
| Verify current official OpenAI documentation | V | Links and decisions in SOURCES.md; reviewed operation and model capabilities |
| Required OpenAI integration behind Swift protocol | V/P | Production native Responses provider and official Agents SDK both returned real proposals; see VERIFICATION.md |
| Official agent framework isolated from Swift desktop | V/P | Python `Agent` + `Runner`, typed output, no tools, private pipes; 6 SDK tests plus actual GPT-5.4/low requests |
| Locate local shell key without exposing it | V | Found assignment name `OPENAI_API_KEY`; key value not printed/dumped/sourced |
| Secure explicit key setup and Keychain storage/removal | V/P | User approved import; stored key and successful retrieval across relaunch verified. Removal implemented but not exercised on this configured key |
| Model picker populated from live account discovery | V | No model allowlist; unknown models use API defaults and are labeled unverified for writing. Live read returned 125 IDs using the environment credential; compatibility is not implied. |
| Model-specific reasoning values and omitted unsupported parameters | V | gpt-4.1/mini omit reasoning; gpt-5.4 supports documented values; invalid combinations fail at wire boundary |
| Persist defaults, per-operation overrides, visible normalization | V/P | Actual settings/action pickers and quit/relaunch retained GPT-5.4/low; unsupported-model effort normalization observed |
| Immutable model/effort request snapshots | V | Constructor captures value types; transport/SDK tests assert requested model/effort; no silent model fallback |
| Audience/context/tone/dialect/style goals | I | Settings implemented and serialized into requests; effect on live results pending |
| Selection, paragraph, entire document rewrite scopes | I | Immutable original/range capture and distinct menu scopes; model call pending |
| Clarity, shorten, expand, simplify, professional/friendly/confident/custom | B | Wired actions and prompts; clarity verified live; other actions and content-quality evaluation pending |
| Tone assessment and adjustment | B | Separate assessment and rewrite actions; no fabricated production analysis |
| Draft from instructions/notes/outline | B | Empty-document draft and source-note workflows implemented; live verification pending |
| Summaries; notes to email/message/outline/structured document | B | Actions implemented; live verification pending |
| Missing context, unclear requests, absent next steps | B | Assessment action returns explanations/recommendations; no facts/citations invented by local code; model behavior needs evaluation |
| Before/after and readable diff | V/P | Token diff tested; real native and SDK model-result diff screenshots captured |
| Accept/copy/regenerate/follow-up/cancel | P | Real native proposal applied; SDK regeneration and immediate close during generation preserved original; Copy remains implemented but not manually tested |
| Fact/name/quantity/date/link/technical-meaning preservation | P | Explicit instructions, protected spans, heuristic change flags and acknowledgement. Never guaranteed |
| Personal voice from explicit samples only | I | Sample entry, cloud describe action, editable profile, enable/disable/delete controls; never derives from ambient documents; live derivation pending |
| Streaming | V/P | Native SSE completed with a real structured result; parser failure tests pass; SDK worker returns at completion |
| Cancellation, timeout, bounded retries | V/P | Native cancellation/timeout/3-attempt server tests and SDK timeout test pass; actual account limits pending |
| Missing key/auth/rate-limit/model/network errors | V/P | Safe mappings and authentication fixture test; useful UI states; real error responses pending |
| Minimal text/context and local/cloud disclosure | I | Selection scope, input caps, explicit cloud notice, no tools, `store: false`; follow-up includes previous proposal by design |
| Opt-in continuous cloud checks | I | Off by default, debounced, capped requests, obsolete results ignored; live rate/cost/quality verification pending |
| Untrusted document text cannot invoke actions | V/P | No model tools; source is serialized as untrusted input; only explicit user accept reaches editor. Prompt-injection quality evaluations pending |
| Validate structured output and ranges | V | Malformed/incomplete/refused/oversized/invalid-range results rejected; no source mutation |
| Old response cannot overwrite new writing | V | Actual AISession apply test against advanced document revision preserves the newer writing |

## Phase 3 — explicit cross-app assistance

| Requirement | Status | Evidence or limit |
| --- | --- | --- |
| Optional permission onboarding and explanation | V/P | Permission absent state verified initially; user subsequently authenticated and granted access; no prompting on editor launch |
| Configurable global shortcut and conflict fallback | I | Public Carbon hotkey registration, 4 choices, status/error and menu fallback; real delivery/conflict test pending AX grant |
| Foreground selection capture with separate source identity | I/B | Permission granted; public AX selected text/range/value/element identity implementation; actual host certification still pending |
| Native nonactivating floating review panel | I/B | SwiftUI in NSPanel, screen clamping; real host-focused screenshot pending physical shortcut/capture verification |
| Replace only exact valid original selection | I/B | Permission granted; app/element/value/range/text revalidation and AXSelectedText-only write implemented; real host mutation pending |
| Refuse changed focus/text/selection; explicit Copy fallback | I/B | Refusal paths implemented; mock/range tests cannot establish host behavior; actual stale-host cases pending |
| Secure/password fields excluded | I/B | Role/subrole/ancestor checks precede text reads; secure-field host tests pending |
| App allowlist/blocklist and pause | V/P | Stored lists, block-over-allow, disabled/paused guards tested; real host-list test pending |
| Clipboard unchanged unless explicit Copy | I | Capture uses AX only; copy action is explicit. Clipboard sentinel manual test pending |
| No continuous/background content collection | V | Capture only from explicit action; observers only while a captured panel exists; no polling collector |
| Transient capture storage | V | Separate in-memory ExternalSelection, never added to library/history |
| Panel invalidation after source change/move/resize | I/B | Workspace/AX notifications plus mandatory final validation; host notification/focus behavior unverified |
| Multiple displays and geometry fallback | P | Pointer-display clamping and optional AX bounds query; no precise underline/anchoring promise; manual multi-display test pending |
| Preserve formatting and undo when host supports them | B | Only native selected-text operation; preservation/undo unknown until each host is tested |
| TextEdit/Notes/Mail/Slack/browser compatibility matrix | B | Installed versions recorded, all real capture/replacement/formatting/undo checks explicitly unresolved; Slack absent at standard path |

## Phase 4 — history, formats, languages, validated continuous assistance

| Requirement | Status | Evidence or remaining steps |
| --- | --- | --- |
| Local revision history, restore and deletion controls | V/P | Snapshots and storage tested; native restore/undo path implemented; full UI restore/delete checklist pending |
| RTF import/export and basic formatting | V/P | Actual attributed text round-trip preserves tested bold and Unicode; heading/list/link controls compiled; broader formatting coverage pending |
| DOCX import/export with tested conversion and warning | V/P | Actual macOS Office Open XML basic bold/Unicode round-trip test passes; conversion warning is mandatory; no fidelity claim for tables/comments/track changes/images |
| English first, supported-language grammar/spelling matrix | P | English native spelling tested, installed dictionaries detected; grammar capability explicitly engine-dependent; comprehensive English grammar corpus and UK differentiation pending |
| Multilingual rewriting/tone/translation | B/P | Input language preservation prompt and explicit Translate target; provider-dependent capability matrix; live multilingual evaluations pending |
| Opt-in continuous focused external field checking | D/B | Not active. First certify a host, add bounded/debounced AX observer session, verify revocation/secure-field behavior and no blocked-app observation, then expose opt-in |
| Anchored indicators/underlines when geometry reliable | D/B | No fake overlay. Must validate AX bounds under scroll/resize/focus changes for a real host before implementation; floating panel remains fallback |
| Store/settings migration and backup documentation | V | Schema guard, additive defaults migration and recovery tests; detailed backup/deletion instructions |
| Document/dictionary/voice/revision deletion; no analytics | V/P | Store purge tests, deletion UI implemented; no local analytics database exists |
| Idle analysis and bounded large-text processing | P | Debounce/cancellation/generation checks; native spelling chunks; local patterns/NER run off main actor over whole source and remain a large-input scaling limit |
| Responsive 10,000-word editing and reported timings | V/P | Measured native test; latest 12 ms initial layout, 26 ms slowest of 20 insertions, 212 ms async spelling; cold earlier insertion reached 82 ms. Full interactive typing/dictation profiling still needed |
| Slow-operation progress and source preservation | V/P | Real native/SDK progress and close-to-cancel exercised; no partial JSON apply; failure/stale tests pass |
| Signing/sandbox/distribution constraints checked | V/P | Official Apple restriction verified; direct Developer ID route documented; local ad-hoc signature built/verified; release signing and notarization not performed |
| Screenshots of actual app | P | Actual editor, settings, native live proposal and SDK live proposal screenshots captured. Real external-selection panel remains pending. No generated/faked screenshots |

## Remaining prerequisites and exact next work

1. Credential import and small live requests were approved and executed. Native mini-model review/application and SDK GPT-5.4/low regeneration/cancellation were verified. The model/effort survived relaunch; actual screenshots are in VERIFICATION.md. Broader writing-action/language quality and real quota exhaustion remain unverified.
2. Accessibility was granted after the user authenticated. Complete the synthetic host cases in COMPATIBILITY.md. Automation keystrokes have not established global shortcut delivery; a physical shortcut check is pending. Do not infer any passing host cells from code alone.
3. Complete the remaining native UI checklist: light mode, keyboard-only/VoiceOver, dictionary controls, import/export panels, revision restore/deletion, IME, dictation, multi-display movement, and login/reboot.
4. Implement continuous external observation and reliable anchored feedback only after the host-specific prerequisites in the table are met. This later-phase work has not been silently treated as complete.
5. Supply a release identity/notary profile, package a managed SDK runtime if desired, perform hardened-runtime testing, sign, notarize, staple, and test Gatekeeper on a clean Mac. Test the macOS 14 deployment floor and Intel separately before advertising them as verified.
