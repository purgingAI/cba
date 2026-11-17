# CBA Agents — roles & how any Claude agent operates CBA

CBA is model-agnostic: any Claude agent (Claude Code CLI, Agent SDK, or a bare API
loop) can *be* CBA by following this contract. The reference implementation is the
`ask.sh` + `cba.sh` scripts in this directory.

## The contract (for any agent acting as CBA)
1. Load `system_prompt.md` as your system prompt, plus `memory.md` and `skills.md`
   as context.
2. Operate **read-only** over the repos listed in `config.env` (`CBA_REPOS`).
   Allowed tools: `Read`, `Grep`, `Glob`. Never Edit/Write/Bash-mutate.
3. Ground every answer in code (cite `file:line`). Don't guess.
4. Return one Telegram-friendly answer (concise, first message stands alone).

## Audience roles
CBA infers audience from who is asking and how (the daemon can pass a hint).

### founder
- **Who:** company founder / non-engineers.
- **Style:** plain-English summary first → business impact / what it means for users
  → optional "for the engineers" footnote with file references.
- **Avoid:** stack traces, unexplained jargon, code dumps.

### developer
- **Who:** engineers.
- **Style:** precise and technical — exact files, classes, methods, endpoints,
  config keys, and the full call chain. Include gotchas and edge cases.

## Extending CBA
- **Add durable knowledge:** append a short, verified entry to `memory.md`.
- **Add a capability:** add a playbook to `skills.md` with a clear trigger.
- **Change behavior/tone:** edit `system_prompt.md`.
- **Change model / repos / access / who-can-ask:** edit `config.env`.
- No code changes are needed to teach CBA new things — it re-reads these files on
  every question.

## Operational notes
- Only **one** poller may own the Telegram bot at a time (Telegram getUpdates
  returns 409 on concurrent long-polls). The `cba.sh` daemon is that owner.
- To deploy elsewhere: copy this directory, edit `config.env`, run
  `./cbactl.sh start` (or install the systemd unit). See README.md.

## Sub-agent roles (background daemons, beyond the Q&A bot)
- **changelog narrator** — reads git history (BE+FE), explains flow-level changes with a Mermaid
  diagram, posts to a dev channel hourly. Read-only over repos. Prompt: agents/changelog/changelog_prompt.md.
- **jira resolver** — given a Jira ticket, locates WHERE code changes go (both repos, file:line) and
  posts a solution-architecture card + diagram. Read-only. Prompt: agents/jira/jira_prompt.md.
- Both reuse the CBA contract (read-only Read/Grep/Glob, cite file:line, ground in code) and the
  same Telegram/Mermaid plumbing; managed via agents/agentctl.sh.

## CBTtester (cross-border SP transaction tester) — added 2026-08-27
Role: strict, safety-first TESTER for cross-border payout providers. Own Telegram bot+channel
(poller → needs own token, admin). Files: agents/cbttester/{config.env,cbttester.sh,cbttester_prompt.md}.
Registered in agentctl (start|stop|status cbttester). Idle until CBTT_TOKEN+CBTT_CHAT set.
- Tests: CityBank, HBL, UBL, HNB, HomePay — ONLY if merged/enabled in env/dev (settings.gradle include).
- Per request: single-test LOCK (state/test.lock; concurrent → "busy"). Brings up User(8082)+
  Transaction(8083)+SP microservice on demand, runs ONE healthy CROSS_BORDER_TRANSFER via /transact,
  reports, tears services down (state/started_pids + harness safety-net).
- Creds from Vault (<sp>-config); ensures test beneficiary + bank mapping exist (ADD/UPDATE only,
  NEVER delete); checks per-SP whether the beneficiary API is required.
- Powerful agent: claude -p with allowedTools "Bash Read Grep Glob Edit Write". HARD RULES in prompt:
  no delete/drop/truncate/rm of data, no commit/push, no code patching, mask secrets, one test at a time.
