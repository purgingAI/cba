# CBA — Code Base Assistant

A real-time Telegram assistant that answers questions about the OpenWallet codebase
(backend `core-api` + frontend `admin-console`) by running a
**read-only Claude agent** grounded in the actual source. Built for the company
founder (plain-English feature/flow answers) and developers (precise, file-level
answers).

## How it works
```
Telegram (channel post / DM)
   → cba.sh daemon (long-polls getUpdates, one owner of the bot)
      → ask.sh  (claude -p, read-only: Read/Grep/Glob, both repos via --add-dir)
         → answer grounded in code with file:line citations
      → reply back to the same chat (auto-split to Telegram's 4096 limit)
```

## Files
| File | Purpose |
|------|---------|
| `config.env` (copy from `config.env.example`) | token, chat, model, repos, tools, timeout — **edit this** |
| `system_prompt.md` | CBA persona + answer rules |
| `memory.md` | durable, verified facts about the codebase |
| `skills.md` | repeatable answer playbooks |
| `agents.md` | roles + contract any Claude agent follows to *be* CBA |
| `ask.sh` | the answer engine (usable standalone) |
| `cba.sh` | the Telegram daemon |
| `cbactl.sh` | start / stop / restart / status / logs |
| `lib.sh` | config + Telegram helpers |
| `cba.service` | systemd unit template |

## Run it (local)
```bash
cd ~/cba
./cbactl.sh start      # start daemon (greets the channel)
./cbactl.sh status
./cbactl.sh logs       # tail -f the log
./cbactl.sh stop
```
Ask a question one-off without Telegram:
```bash
./ask.sh "How does the incentive discount flow work?" developer
```

## Deploy on a server
1. Copy `~/cba` to the server; ensure the two repos exist (paths in `config.env`)
   and the `claude` CLI is installed and authenticated for the service user.
2. Edit `config.env` (token, `CBA_REPOS`, `CBA_MODEL`, and — for a public host —
   set `CBA_ALLOWED_CHATS` to lock down who can ask).
3. Install the service:
   ```bash
   sudo cp cba.service /etc/systemd/system/cba.service   # edit User/paths first
   sudo systemctl daemon-reload
   sudo systemctl enable --now cba
   sudo journalctl -u cba -f
   ```

## Usage in Telegram
- **Founder / admins:** post a question in the channel → answer arrives in the channel.
- **Developers:** DM `@openwalletDeadlineBot` → answer arrives in the DM.
- Commands: `/help`, `/status`, `/ping`.

### Document / Postman generation (artifacts)
Ask CBA to "generate a document / report / Postman collection / JSON …" and it:
1. generates the file(s) grounded in the real code,
2. uploads each as a **Telegram document** (no chunked-text spam),
3. offers to **email** them — reply with an address and CBA sends them to your
   inbox (or reply "no").

Email needs SMTP settings in `config.env` (`CBA_SMTP_HOST/PORT/USER/PASS/FROM`).
For Gmail use an **App Password** (requires 2FA), not the account password.
Without SMTP set, artifacts still arrive in Telegram; only the email step is skipped.

## Safety
- **Read-only by design.** Allowed tools are `Read Grep Glob`; `Edit`, `Write`,
  `Bash`, `NotebookEdit` are explicitly disallowed. Anyone who can message the bot
  can *ask about* code but cannot change anything or run commands.
- **Single poller.** Only one process may own the bot's `getUpdates`. Don't run a
  second poller (Telegram returns 409).
- Rotate the bot token if it has been shared in plaintext.

## Teach CBA new things (no code changes)
- Add a fact → append to `memory.md`.
- Add a capability → add a playbook to `skills.md`.
- Change tone/rules → edit `system_prompt.md`.
- Change model/repos/access → edit `config.env`, then `./cbactl.sh restart`.
