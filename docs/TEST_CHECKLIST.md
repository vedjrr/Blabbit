# Manual insertion checklist (human-run, every release)

For each app: focus a text field, hold **⌥ Space**, say **"Testing Utter, one two three. HoldMyCode uses PostgreSQL."**, release.

**Pass** means: the exact text appears at the cursor; the clipboard is unchanged afterwards (copy `SENTINEL` beforehand, paste after); focus doesn't change; no stray keystroke (no space or `…` typed by the shortcut).

**How to read the result:** every dictation writes one `dictation …` line to `~/Library/Logs/Utter/utter.log` (menu → Open Log). Copy these fields into the table:
- `result`:
  - `inserted(accessibility)` / `inserted(paste)` / `inserted(typing)`: the text went in and was confirmed.
  - `unverified(accessibility)`: the field changed in an unexpected way; the text is probably there. It is also on the clipboard, and the menu bar icon shows a bubble for 4 s.
  - `unverified(paste)`: the app never read the pasted clipboard (paste blocked, no text field focused, a VM or remote desktop). The text is on the clipboard; nothing was typed or submitted. If an app always does this, set it to typing (override recipe below).
  - `blockedBySecureInput`: secure input or a password field; nothing was typed (lock icon for 4 s).
  - `copiedToClipboard`: the "clipboard only" method is selected. `handledByScript`: the external script got the text.
  - `failed(...)`: every method failed; the text is on the clipboard and the reason is in `attempts`.
- `release_to_insert_done_ms`
- `clipboard_readable`
- `attempts`: why earlier strategies were skipped

The expected strategy comes from the default per-app table (`app/Sources/UtterKit/InsertionStrategy.swift`). "AX" means Accessibility: the text is set directly in the field, and the clipboard is never touched.

| App | Field tested | Expected strategy | Strategy used | Latency (ms) | Clipboard kept | Pass |
|---|---|---|---|---|---|---|
| TextEdit | document | AX | | | | |
| Notes | note body | AX | | | | |
| Mail | compose body | AX | | | | |
| Messages | message box | AX | | | | |
| Xcode | source editor | AX | | | | |
| Safari | textarea on any form | paste | | | | |
| Chrome | Google search box | paste | | | | |
| Arc | address bar + textarea | paste | | | | |
| VS Code | editor + terminal | paste | | | | |
| Cursor | editor + chat | paste | | | | |
| Terminal | zsh prompt | paste | | | | |
| iTerm2 | zsh prompt | paste | | | | |
| Slack | message box | paste | | | | |
| Discord | message box | paste | | | | |
| WhatsApp | message box | paste | | | | |
| Notion | page block | paste | | | | |
| ChatGPT (web + app) | prompt box | paste | | | | |
| Password field (any) | secure field | **must NOT insert** (`blockedBySecureInput`) | | | | |

**Extra checks**
- Terminal → Terminal menu → **Secure Keyboard Entry** on, then switch to TextEdit: ⌥Space should still start recording (Carbon fallback; the log shows `carbon fallback registered`). Nothing is typed; the text lands on the clipboard and the menu says so (`result=blockedBySecureInput`). In a password field the text must be dropped, not copied.
- Unplug or switch a Bluetooth mic mid-recording. There should be no crash, the log shows `device_changed=true`, and the part before the switch is transcribed.
- A 5-minute recording.
- A 0.2 s tap should do nothing (the log shows `skipped_TooShort`).
- Per-app override: set Terminal to "Type" (Settings → Text Insertion; until Settings exists in M5: `defaults write dev.utter.mac insertion.overrides -data "$(printf '{"com.apple.Terminal":["typing"]}' | xxd -p | tr -d '\n')"`), then dictate. The log should show `inserted(typing)`.
