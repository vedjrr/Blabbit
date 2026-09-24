# Manual insertion checklist (human-run, every release)

For each app: focus a text field, hold hotkey, say **"Testing Utter, one two three. HoldMyCode uses PostgreSQL."**, release.

Pass = exact text appears at cursor, clipboard unchanged afterwards (copy "SENTINEL" beforehand, paste after), no focus change, no stray keystroke.

| App | Field tested | Strategy used | Latency (ms) | Clipboard kept | Pass |
|---|---|---|---|---|---|
| TextEdit | document | | | | |
| Notes | note body | | | | |
| Safari | textarea on any form | | | | |
| Chrome | Google search box | | | | |
| Arc | address bar + textarea | | | | |
| VS Code | editor + terminal | | | | |
| Cursor | editor + chat | | | | |
| Xcode | source editor | | | | |
| Terminal | zsh prompt | | | | |
| iTerm2 | zsh prompt | | | | |
| Slack | message box | | | | |
| Discord | message box | | | | |
| WhatsApp | message box | | | | |
| Messages | message box | | | | |
| Mail | compose body | | | | |
| Notion | page block | | | | |
| ChatGPT (web) | prompt box | | | | |
| Password field (any) | secure field | should NOT insert | | | |

Extra: unplug/switch Bluetooth mic mid-recording; 5-min recording; 0.2 s tap (should do nothing).
