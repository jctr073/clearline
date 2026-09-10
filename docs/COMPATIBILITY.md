# Cross-app compatibility and manual verification

**No external application is certified yet.** Clearline is running on a real Mac, and its Accessibility permission was granted with user authentication. Host capture/replacement checks are still pending. Code and mock tests cannot establish host compatibility. Do not advertise universal inline correction, universal formatting preservation, or universal undo.

Installed app versions were read from their actual bundle metadata on September 9, 2026, on macOS 26.6.2. Version discovery is not a capture test.

| Host | Installed version (build) | Selection capture | Selected-text replacement | Formatting | Host undo | Focus/stale-source checks |
| --- | --- | --- | --- | --- | --- | --- |
| TextEdit | 1.20 (415) | Not tested; permission now granted | Not tested | Not tested | Not tested | Not tested |
| Notes | 4.13 (3146.141.6) | Not tested; permission now granted | Not tested | Not tested | Not tested | Not tested |
| Mail | 16.0 (3864.700.51.1.1) | Not tested; permission now granted | Not tested | Not tested | Not tested | Not tested |
| Slack | Not installed at `/Applications/Slack.app` | Requires app installation | Not tested | Not tested | Not tested | Not tested |
| Chrome text fields | Chrome 152.0.7977.83 (7977.83) | Not tested; website/editor must be recorded | Not tested | Not tested | Not tested | Not tested |
| Safari text fields | Safari 26.6.2 (21624.5.1.11.3) | Not tested; website/editor must be recorded | Not tested | Not tested | Not tested | Not tested |

Default allowlisting of `com.apple.TextEdit` means only that a user can choose to try it after granting permission. It is **not** a pre-certified host.

## Host test procedure

Use new, unsent, disposable test documents. Do not test with real passwords, messages to other people, or sensitive documents. For browser tests, use a local ordinary textarea, a contenteditable field, and a password field separately; record the page/editor implementation rather than attributing all behavior to “Chrome.” No extension or DOM injection is part of Clearline.

1. Record the exact host version and whether Clearline has AX permission. Allow only that host in Settings. Keep cloud automatic checking off.
2. Type `Please send the draft to Ada on September 15. Budget: 42 units. 😀 café שלום.` Select only `Please send the draft` and invoke the configured shortcut. Confirm the original and host identity in the panel.
3. With configured OpenAI, request a small clarity edit. Check model/effort before sending. Compare the proposal and explicitly accept only a synthetic test edit.
4. Verify the prefix/suffix outside the selection are unchanged, the selection was replaced exactly, and nothing was copied automatically. Record whether the host provides one-step Undo and Redo; do not infer this from another host.
5. Repeat with bold/italic mixed formatting, a link, multiline text, emoji before and within the selection, a combining-mark sequence, non-Latin text, and right-to-left text. Record exactly which attributes survive.
6. Capture, then edit the source. Attempt Replace: it must refuse or the panel must invalidate. Repeat separately after moving the selection, focusing another field, changing to another app, closing the source, and reopening a similar-looking document.
7. Move/resize the source window and scroll the field. Ensure stale overlays/panels are not left attached; the shipped panel is the fallback and does not promise inline positioning.
8. Capture, revoke Accessibility permission in System Settings, then attempt Replace. It must refuse with a usable explanation. Confirm ordinary document editing still works.
9. Try a password field containing only a synthetic dummy value: capture must be refused before reading content. Block the app and repeat: no capture is allowed. Global Pause must also stop capture.
10. Place a non-sensitive sentinel on the clipboard yourself. Invoke capture and Cancel; verify the sentinel is unchanged. Then explicitly choose Copy and verify only the proposal replaces it. Never use a hidden paste fallback.
11. Select non-editable text that exposes a selection through Accessibility. Confirm the passage opens in the proposal panel with no Replace button. Generate, then test Copy and Append to workspace document separately. Append must name its destination, preserve existing text and formatting, add the proposal at the end, close after success, and support Undo. Repeat with no workspace document, an empty document, and after switching workspace documents. Read-only capture must remain usable after source changes or app switching. If the host exposes no supported selection, show the manual copy/paste explanation. Never allow a whole-field replacement fallback.
12. Check shortcut conflict handling, menu-bar invocation while the source remains frontmost, focus while entering panel instructions, Cancel without editing, multiple screens, and source app termination.

Record each dimension independently: pass, unsupported, failed, or not tested. If any identity/value/selection check cannot be established, leave replacement unsupported for that host/control.

## Why continuous external checking is not active

On-demand capture is implemented, but its host assumptions have not yet been validated here. An opt-in continuous mode needs a tested AX observer lifecycle, bounded context, debounce, permission/secure-field rechecks before every read, reliable focus changes, and no observation of blocked apps. Anchored indicators additionally need a tested range-to-screen geometry contract under scroll, resize, and editing. These are remaining in-scope requirements, not shipped functionality. The current UI explicitly says they are unavailable.
