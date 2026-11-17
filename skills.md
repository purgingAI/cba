# CBA Skills — what CBA can do and how

Each skill is a repeatable playbook. When a question matches a trigger, follow the
approach. All skills are **read-only**.

## 1. explain-feature-flow
**Trigger:** "how does X work", "explain the <feature> flow", "walk me through …".
**Do:** Find the entry point (Grep for the endpoint/route or UI action) → follow the
call chain through service/handler classes → identify data changes (MySQL tables /
Mongo collections) → describe the outcome. Present as: 1-line summary, then an ordered
flow with `file:line` citations, then edge cases (failures, reversals).

## 2. locate-code
**Trigger:** "where is X", "which file handles Y", "find the class that …".
**Do:** Glob/Grep across both repos. Return the file path(s) with line numbers and a
one-line description of each match. Rank by relevance.

## 3. api-contract
**Trigger:** "what's the request/response for endpoint Z", "fields for …".
**Do:** Read the controller + DTOs. List HTTP method, path, required headers, request
fields (with types), response shape, and the RBAC permission string it needs.

## 4. impact-analysis
**Trigger:** "what breaks if I change X", "what depends on Y".
**Do:** Grep for usages/references across both repos; list callers and downstream
effects. Be explicit about what you did and did NOT check.

## 5. config-lookup
**Trigger:** "what port/queue/table/env var does X use".
**Do:** Read application.yml/properties, constants, and `@Value` bindings. Cite the
config key and its resolved source (yaml, vault, env).

## 6. status / meta
**Trigger:** `/help`, `/status`, `/ping`, "what can you do".
**Do:** Handled by the daemon directly (no Claude call) — quick canned replies.

## 7. generate-artifact (documents / Postman / reports)
**Trigger:** "generate/create/write/produce a document/report/guide/spec/Postman
collection/JSON/CSV/…". Detected by `is_artifact_request` in the daemon.
**Do:** `artifact.sh` runs a read-only Claude pass that PRINTS each deliverable as
`===CBA_FILE: <name>===` + raw content; the daemon writes those to
`state/artifacts/<ts>/` and uploads each as a **Telegram document** (not chunked
text). Then CBA offers to email the files: reply with an address → `send_mail.py`
sends them via SMTP (config in `config.env`); reply "no" to skip. Always ground
endpoints/fields in real code; produce valid Postman v2.1 JSON when asked.

## 8. live-data lookup (read-only)
**Trigger:** questions about ACTUAL records — "last split payment", "fund flow for
txn X", "campaign 79 live budget", "how many redemptions today".
**Do:** Use the `dbq` tool (Mongo find / MySQL SELECT, read-only, row-capped). Pull
transaction legs → walletLedger → settlement/fee. State that data is live; never
decrypt PII (encrypted fields → label/omit). Enabled when `CBA_DB_ENABLED=true`.

## 9. actions (WRITE — 31st Deadline channel only)
**Trigger:** "reinitiate/re-run/redo the payment/transaction".
**Do:** Only on instances with `CBA_WRITE_ENABLED=true`. The daemon builds a PLAN
from live data, posts it, and requires the human to reply **CONFIRM** before the
allow-listed action (`actq rerun-p2m …`) runs. Every action is appended to
`state/actions.log`. Split/cross-border replay is NOT automated. The dev CBA
channel is read-only (no actions).

## Answer hygiene (applies to every skill)
- Verify before asserting; cite `file:line`.
- Say "I couldn't find …" instead of guessing.
- Keep it Telegram-sized; structure long answers so message 1 stands alone.
- Never propose to run mutating commands; describe changes instead of making them.

## 8. boot-incentive-engine-local
**Trigger:** "how do I run/boot IncentiveEngine (or HBL) locally".
**Do:** config is Vault-only (`application-local.yml` deleted) so: `ln -sfn ../config
IncentiveEngine/config`; export `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` (Vault datasource,
else JPA falls back to root@localhost); export `SECURITY_JWT_EXPIRATION_TIME_EXPOSED_PORTAL=900000`
(dodge Authorizer JwtService SpEL int-overflow); then `SPRING_PROFILES_ACTIVE=local ./gradlew
:IncentiveEngine:bootRun` (8299). Redis cluster is reachable via Vault. HBL (8092) uses the same
pattern minus the JWT var, plus `SPRING_AUTOCONFIGURE_EXCLUDE` for security/JPA if booting lean.

## 9. call-secured-endpoint-local (mint JWT)
**Trigger:** "how do I call a secured endpoint / get a token locally".
**Do:** endpoints are JWT-secured (Authorizer). Mint an HS512 token signed with Vault
`security.jwt.secret-key`, claims `username`/`userKey`=<userId>, `role`/`role_type`, `locale`,
`log`. CUSTOMER role is accepted by casbin for `/customer/*`. Send `Authorization: Bearer <token>`.

## 10. seed-service-provider-error-codes
**Trigger:** "how do I add/seed error-code mappings for a service provider".
**Do:** uncomment the `save<Provider>(...)` block in `DataInitialisationServiceImpl`, start
Transaction, GET `/transaction/makeErrorCodeMapping` once (writes `service_provider_error_code`),
then re-comment the block. Verify: `SELECT code,status FROM service_provider_error_code WHERE
service_provider_id=<id>`. Codes map to base `transaction_error_code` (1000 SUCCESS / 1002 PENDING
/ 1001,1009,1011,1012,1014 FAILED).

## 11. configure-sub-agents (changelog / jira)
**Trigger:** "set up / configure the changelog (or jira) agent".
**Do:**
- changelog: set `CHLOG_CHAT` (post channel) in `agents/changelog/config.env` (optionally
  `CHLOG_BE_BRANCH`/`CHLOG_FE_BRANCH`), then `agents/agentctl.sh restart changelog`. Posts on the
  next new commit; force a test pass with `agents/changelog/changelog.sh once`.
- jira: create a dedicated bot, make it ADMIN of the Jira channel, set `JIRA_TOKEN` + `JIRA_CHAT`
  in `agents/jira/config.env`, `agents/agentctl.sh start jira`, add a crontab watchdog line.
