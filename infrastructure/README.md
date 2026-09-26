# Infrastructure (Terraform)

IaC for A&E RV Solutions. Step 1: hosting the Astro site in [`site/`](../site)
— done as two parallel, independent Terraform stacks, one per hyperscaler:

- `aws/` — AWS Amplify Hosting
- `azure/` — Azure Static Web Apps

They're **alternatives, not a dual-cloud deployment**: pick one to actually
provision and run. Both stacks live in the repo so you can switch later, or
compare them, without rewriting anything. Later steps (not yet built): a
knowledge library and an AI chatbot backend, added to both stacks
equivalently as they're built.

Each stack has the same shape:

- `bootstrap/` — one-time, local-state config that creates the remote state
  backend (bucket/table for AWS, storage account/container for Azure). Run
  once per cloud account.
- `modules/` — the reusable hosting module (`amplify` / `static-web-app`).
- `live/prod/` — the only environment right now. Calls the module, using
  the backend `bootstrap` created.

## Why deploys go through GitHub Actions instead of a cloud-native push trigger

The site lives in `site/`, and infrastructure changes live in
`infrastructure/`, in the same repo. A push to `main` that doesn't touch
the site must **never** trigger a rebuild/redeploy of it, so
`deploy-site.yml` is gated with `paths: ["site/**"]` — an allow-list, so
*only* site content deploys.

Neither cloud's native push trigger is used:

- **AWS**: Amplify's own trigger (`enable_auto_build`) is disabled
  entirely — its documented "monorepo app root" build-trigger filtering has
  multiple open bug reports of triggering builds on every commit regardless
  of path (see `aws/modules/amplify/main.tf`). The `deploy-aws` job POSTs
  to an Amplify webhook instead.
- **Azure**: Static Web Apps' Terraform resource doesn't take a GitHub
  connection at all — deployment is *only* ever driven by a CI workflow
  using a deploy token, so there's no native trigger to disable. The
  `deploy-azure` job runs the official `Azure/static-web-apps-deploy`
  action.

## Where each piece of automation runs

Two PR checks gate what can merge. Two deploy workflows then act on what
merged, each gated to its own paths so neither fires for the wrong kind of
change. A third publishes the chatbot's knowledge base, and one manual
workflow switches the chatbot on or off:

| Workflow | Triggers on | What it does |
|---|---|---|
| `site-ci.yml` | Every PR to `main` (builds only when `site/**` changed) | `astro check` + `astro build`. Required check |
| `terraform-aws-plan.yml` | Every PR to `main` (plans only when `infrastructure/aws/**` changed) | `fmt -check`, `validate`, and `terraform plan` for `live/prod` using a read-only role, posted as a PR comment. Required check: a failing plan blocks the merge |
| `terraform-aws.yml` | `infrastructure/aws/live/**`, `infrastructure/aws/modules/**` (on merged PR) | Runs `terraform apply` against AWS, authenticated via OIDC (no stored keys) |
| `deploy-site.yml` | `site/**` | Reads [`deploy-targets.yml`](deploy-targets.yml), then deploys to each cloud whose flag is `true` |
| `chatbot-toggle.yml` | Manual: Actions → "Chatbot on/off" → Run workflow | Sets the chatbot's on/off flag. Takes effect in seconds; no PR or deploy (see [Chatbot](#chatbot)) |

`infrastructure/aws/bootstrap/**` deliberately isn't in `terraform-aws.yml`'s
path filter — `bootstrap` stays a local, one-time step (see below), since
it creates the very state backend and CI trust role that `terraform-aws.yml`
depends on.

### `deploy-targets.yml` controls which clouds deploy

```yaml
aws: true
azure: false
```

`deploy-site.yml`'s `read-targets` job reads this file and exposes each flag
as a job output; `deploy-aws` and `deploy-azure` are each gated on their own
flag being `"true"`. Flipping a flag is the only thing needed to turn a
cloud's deploys on or off — no workflow edits.

If a flag is `true` but that cloud's secret (`AMPLIFY_WEBHOOK_URL` /
`AZURE_STATIC_WEB_APPS_API_TOKEN`) is missing, the job fails loudly with an
explicit message rather than skipping silently — a `true` flag is a
statement of intent, so a missing secret is a misconfiguration worth
surfacing.

## Guardrails and safety

`terraform-aws.yml` applies with `-auto-approve` as soon as a PR merges, so
every safeguard has to act **before** the merge. Four layers do that:

```
PR opened ─► required checks (plan gate) ─► ruleset allows merge ─► apply on merge
                  │                                                     │
                  └── prevent_destroy fails the plan ◄──────────────────┘ (and the apply, as a backstop)
```

### 1. Branch ruleset on `main`

A repo ruleset named **main protection** (Settings → Rules → Rulesets):

- **Every change goes through a PR.** Direct pushes, force-pushes, and
  deleting `main` are all rejected.
- **Four required checks:** `changes` + `site-build` (`site-ci.yml`) and
  `tf-changes` + `terraform-plan` (`terraform-aws-plan.yml`). They must come
  from the GitHub Actions app, so nothing else can report them green.
- **No review approvals are required.** This is a solo repo, and GitHub
  doesn't let you approve your own PR.
- **Override:** the repo admin role has a **PR-only bypass**. A PR with red
  checks can be force-merged with `gh pr merge <n> --admin` or the web
  "bypass rules" checkbox, but direct pushes stay blocked even for admins.
  Every override therefore still leaves a PR on record.

Both PR workflows run on **every** PR and skip their real work when their
paths are untouched. A path-filtered required check never starts, so it
would leave unrelated PRs stuck on "Expected — waiting". A job skipped by its
`if:` reports success. The `changes`/`tf-changes` detector jobs are
required too: if one errors, its skipped build or plan job can't count as a
pass.

### 2. Plan on every infrastructure PR

`terraform-aws-plan.yml` runs `terraform fmt -check -recursive` (all of
`infrastructure/aws`, including `bootstrap/`), `validate`, and a real `plan`
of `live/prod`. It posts the plan as **one PR comment, updated in place on
every push**: ✅ with the plan summary, or ❌ with the error. Any failure
fails the `terraform-plan` check, which blocks the merge.

`bootstrap/` is formatted and validated but never planned or applied in CI.
It's a local, manual step (see "Deploying to AWS").

### 3. `prevent_destroy` on resources whose loss takes the site down

| Resource | Why it's protected |
|---|---|
| `aws_route53_zone.primary` | A recreated zone gets **new nameservers**, and the domain stops resolving until they're changed at GoDaddy |
| `aws_amplify_app.this` | Hosts the site. Recreating it drops the app, its branch, and the domain |
| `aws_amplify_branch.this` | The production branch the domain points at |
| `aws_amplify_domain_association.this` | The live domain and its certificate. Also catches `count` dropping to 0 |
| `aws_s3_bucket.tfstate` (bootstrap) | Holds every stack's state |

Any plan that would destroy **or replace** one of these fails with
`Error: Instance cannot be destroyed`. That fails the PR check, and it would
also fail the apply, as a second line of defense. The Amplify webhook is
deliberately *not* protected: recreating it only rotates its URL, and
`deploy-site.yml` fails loudly on the stale secret.

**Tearing one down on purpose:** remove its `prevent_destroy` in its own
PR, merge that, and then make the destructive change in a second PR.

**Known limitation:** deleting a resource block deletes its
`prevent_destroy` along with it. For that case, the posted plan is the
safeguard, so read the "to destroy" count before merging.

### 4. Least privilege for CI

- **No stored AWS keys.** Both workflows assume IAM roles through GitHub
  OIDC.
- **Apply role** `github-actions-terraform`: trusted only for jobs that
  declare the `aws-infra` GitHub Environment, which only the apply job does.
- **Plan role** `github-actions-terraform-plan`: trusted for this repo's
  `pull_request` subject, and read-only:

  | Access | Scope |
  |---|---|
  | Read state | `live/prod/terraform.tfstate` only |
  | Write | Only the `live/prod/terraform.tfstate.tflock` lock object |
  | Amplify | `GetApp`, `GetBranch`, `GetDomainAssociation`, `ListTagsForResource` on the one app; `GetWebhook` |
  | Route 53 | `GetHostedZone`, `ListTagsForResource` on the one zone |

  The repo is public. Fork PRs never receive an OIDC token, but any branch
  in this repo can edit workflows, which is why this role can't change
  anything. When a new resource type makes a CI plan fail with
  `AccessDenied`, add **the exact action it names** to the policy in
  `bootstrap/main.tf` and re-apply bootstrap locally. Don't widen it to a
  wildcard.
- **The GitHub PAT never reaches PR jobs.** The plan passes a placeholder
  `github_access_token`. `access_token` has `ignore_changes`, so its value
  can't affect the plan. Only the apply job gets the real
  `AMPLIFY_GITHUB_TOKEN` secret.

### Secrets in public logs

Actions logs and PR comments on a public repo are world-readable. The
Amplify webhook URL contains a token that can start builds, and the AWS
provider doesn't mark it sensitive. Both Terraform workflows therefore
register it with `::add-mask::` before `plan`/`apply`. The plan workflow
also redacts `token=…` from the PR comment, because masking only covers
logs.

### Running Terraform locally behind TLS-inspecting antivirus

Antivirus that re-signs HTTPS traffic (e.g. Norton Web/Mail Shield) breaks
local Terraform in two ways:

- **Localhost.** Terraform talks to its provider plugins over TLS on
  `127.0.0.1`. When that connection is intercepted, every command fails with
  "Failed to load plugin schemas … Plugin did not respond".
  `TF_LOG=trace` shows `x509: certificate signed by unknown authority`.
  Exclude `127.0.0.1`/`localhost` from HTTPS scanning.
- **Silent wrong data.** Anything computed from a certificate the machine
  sees gets the antivirus's forged certificate instead. This is why
  `bootstrap` no longer computes the GitHub OIDC `thumbprint_list` from a
  `tls_certificate` lookup. AWS ignores thumbprints for GitHub's OIDC
  endpoint, and the stored value stays as it is.

The AWS CLI is also affected, because it ships its own trusted certificate
authorities (`CERTIFICATE_VERIFY_FAILED`). Exclude `*.amazonaws.com` from
HTTPS scanning.

### Not yet covered

- Pinning the Terraform version in CI, and removing the unused DynamoDB
  lock table.
- Narrowing the **apply** role, which still has `amplify:*` and broad
  Route 53 access on `*`, and adding `default_tags`.
- Static analysis (tflint/checkov).
- Per-visitor rate limiting for the chatbot (AWS WAF). See [Chatbot](#chatbot).
- MFA that's enforced by Cognito for employees. See [Employees](#employees).

## Chatbot

**Eddie**, a public chat assistant on the site: the on/off flag, a safety
gate, the owner's [knowledge base](#knowledge-base), and Claude Haiku 4.5 on
Bedrock. Eddie speaks for the company as "we/us" and says he's an AI if
asked. It lives in
[`aws/modules/chatbot/`](aws/modules/chatbot). Its CI permissions, toggle
role, owner-alert topic, and monthly budget live in
[`aws/bootstrap/chatbot.tf`](aws/bootstrap/chatbot.tf).

```
Widget ─GET /chat/status (no key)─► API Gateway ─► SSM flag ─► {"enabled": true|false}
Widget ─POST /chat (x-api-key)─► API Gateway REST API
   │  request schema (≤8 messages, ≤500 chars per customer message) ─► 400, nothing billed
   │  usage plan: 1 req/s, burst 3, 50 per day ─► 429 "busy"
   └► Step Functions EXPRESS (synchronous)
        CheckFlag ─ off/unreadable ─► fixed "offline" reply
          └► Validate ─► Classify (Haiku 4.5, forced strict tool call)
               ├ emergency        ─► fixed emergency reply
               ├ safety_referral  ─► fixed technician referral  ← required safety gate (CLAUDE.md)
               ├ decline          ─► fixed decline (extraction / bulk / off-topic)
               ├ answer           ─► Retrieve (knowledge base: ≤4 passages, score ≥ 0.4; failure → none)
               │                      ─► Answer (Haiku 4.5: assistant.md rules + personality.md + <documents>;
               │                                 forced `respond` tool → {reply, source})
               └ error / anything else ─► safety_referral (fails closed)
```

**Bedrock access is IAM, not an API key.** The state machine's role has
`bedrock:InvokeModel` on the `us.` Haiku 4.5 inference profile and the
foundation model in each region that profile routes to. Usage bills to the
AWS account. There is no Anthropic account or key. The `x-api-key` the site
sends is API Gateway's usage-plan key, which is public by design: it only
applies the throttle and daily quota. The account needed Anthropic's
one-time model-access use-case form, submitted in the Bedrock console.

### Turning it on or off

- **Normally:** the **Feature Mgr** admin page on the site (admins only). It
  calls `POST /admin/features/eddie` on the employee API. It shows each
  switch's recent changes and who made them.
- **Backup:** the Actions tab → **Chatbot on/off** → Run workflow → `on` or
  `off`. It works when the site or sign-in is down, and from the GitHub
  mobile app.
- **Last resort:** `aws ssm put-parameter --name /ae-rv/chatbot/enabled
  --value false --overwrite` (or edit the parameter in the console, under
  Systems Manager → Parameter Store).

All three flip the same parameter, so they never disagree.

Herman has his own switch on the same page. See [Herman, the employee
assistant](#herman-the-employee-assistant).

**Who changed it** comes from the parameter's own version history (the last
100 versions), which the Feature Mgr page shows:
- **Page changes:** the version's description names the admin ("Off: set on
  the Feature Mgr page by …"), and the admin function logs one line with the
  admin's user ID.
- **Workflow changes:** attributed to the workflow's role. Its run history
  shows who ran it.
- **Terraform:** changes made by Terraform's CI role, such as creating the
  switch, show as "Terraform".
- **Anything else:** shown as the AWS identity.

The API enforces the flag on every request, so switching it off also stops
bots that call the API directly without loading the site. Off costs nothing:
the state machine stops before any Bedrock call. Terraform creates the flag
as `false` and ignores its value and description afterwards, so an apply
never undoes a toggle or its note.

**Adding a switch** takes three things:
1. an SSM parameter holding `true` or `false`;
2. an entry in `feature_flags` in `live/prod/main.tf`, which also grants the
   admin function access to it;
3. an entry in `FEATURES` in `modules/employees/lambda/features.py`.

Whatever the switch controls has to read the parameter itself.

### Volume and cost controls

| Control | Setting (module variables) |
|---|---|
| Daily quota, all visitors combined | `daily_quota` = 50 |
| Throttle | `throttle_rate_limit` = 1/s, `throttle_burst_limit` = 3 |
| Conversation caps | `max_messages` = 8, `max_user_message_chars` = 500, `max_assistant_message_chars` = 2500 |
| Answer length | `answer_max_tokens` = 600 |
| Usage-spike email | more than `spike_alarm_threshold` = 25 chats in an hour |
| Monthly budget email (account-wide) | $20, alerts at 50/80/100% (`bootstrap`, `monthly_budget_usd`) |

Pricing (Bedrock, us-west-2, `us.` profile): $1.10 per million input tokens
and $5.50 per million output tokens. A typical chat costs well under a cent.
The worst case, with the quota maxed out every day, is roughly $18 a month.

There's **no per-visitor limit** (that would need AWS WAF). One bot can use
up the day's quota, after which everyone sees "busy" until the next day. The
spike email tells you; switch the chatbot off if it isn't real traffic.
Adding WAF (per-IP rate limit, IP reputation, bot challenge) is the upgrade
path if that happens.

### Anti-distillation, and its limits

- The classifier's `decline` route answers with fixed text when someone asks
  for the assistant's instructions, bulk dumps or lists, generated Q&A or
  training data, or tries to change its role.
- The assistant prompt refuses to reveal its instructions.
- Short answers and the conversation caps limit what a single session can
  pull out; the daily quota limits the total.
- Customer messages reach the classifier as quoted data inside
  `<conversation>` tags, not as instructions.
- Step Functions logs errors only, without execution data. Conversations
  are stored only as transcripts (below), in a private bucket CI can't read.

None of this stops a patient, human-paced extractor. It makes bulk
extraction slow, capped, and noisy. This matters most once v2 adds a
knowledge base: design it to return short grounded answers, never whole
documents or raw chunks.

### Chat transcripts

Every exchange is saved as one JSON file in the private bucket
`ae-rv-chatbot-transcripts-<account>`, at
`transcripts/YYYY/MM/DD/HHMMSS-<execution>.json` (UTC). The state machine's
last state, `Record`, writes it, and S3 deletes it after 30 days
(`transcript_retention_days`).

| Stored | Never stored |
|---|---|
| The time, the execution ID, and a **conversation ID**: a random UUID the widget creates per conversation and keeps only in the tab's session storage (no cookie). It groups a visitor's exchanges and isn't tied to the visitor. Requests without one get the execution ID, so the exchange stands alone | IP addresses, user agents, or any other identifier (the API forwards only the messages and the conversation ID) |
| The route (answer, safety_referral, emergency, decline, unavailable, invalid, offline) and the source label | |
| The conversation the widget sent (at most 8 messages) and Eddie's reply | |
| Input and output token counts for the Classify and Answer calls | |
| **Timings** (milliseconds): `flagMs`, `classifyMs`, `retrieveMs`, `answerMs` and `totalMs`. Each is the gap between `$millis()` stamps the state machine assigns as each step finishes, so a step that didn't run is `null`. Transcripts from before 2026-09-26 have none | |

- **Every reply is recorded**, including offline and safety referrals, so
  usage totals are complete.
- **Storage can't break a chat.** A failed write is caught, and the reply
  goes out unchanged.
- **Least privilege:**
  - the state machine can only write under `transcripts/`
  - the CI roles can configure the bucket but can't read transcripts
- **Browse them** in the S3 console (the `chat_transcripts_bucket` output),
  or on the admin **AI Stats** page. AI Stats shows usage, cost, and the
  median and slowest response time per day, and each exchange's step
  timings.
- **Why S3 rather than DynamoDB:** at the 50-a-day quota, both cost well
  under a cent a month. Files are simpler to expire, browse, and download.
- The chat widget doesn't yet tell visitors that chats are stored. That
  notice ships with a later site update.

### Changing the prompts or routes

The prompts are versioned files in `prompts/`:
- `classifier.md`: the safety gate's routing.
- `assistant.md`: the answer rules (safety, anti-extraction, how to use
  documents, numbers only from documents).
- `personality.md`: the voice (friendly, direct, RV enthusiasm) and the
  "one more capability" rule. Tone changes go here, so they never touch
  the safety text.

The fixed replies are `local.replies` in `main.tf`.

**Answer sources.** Each `answer` reply carries `source`:
- `knowledge_base`: from the owner's knowledge base.
- `both`: the knowledge base plus general knowledge.
- `general`: the model's general (training) knowledge. Eddie doesn't
  search the internet.

The model reports it through the `respond` tool. The state machine forces
`general` whenever no passages were retrieved, so an answer can never be
credited to the knowledge base unless the knowledge base supplied
something. The widget shows it as a caption. A change shows up in the PR's plan comment as a state-machine
update. **Before merging any change to routing, rerun the safety eval**
(hazardous, emergency, extraction, jailbreak, and benign prompts) and confirm
that no hazardous prompt routes to `answer`:

```
cd infrastructure/aws/modules/chatbot/eval
AWS_PROFILE=OTS-Prod-Deploy python run_eval.py
```

It reads the **deployed** Classify request (model, prompt, and tool), so run
it after the prompt change is applied, and before switching the chatbot back
on for customers. Each case costs about $0.002. The run exits non-zero if any
hazardous or emergency case is routed to `answer`. Test cases live in
`eval/cases.json`; add one whenever a real conversation is routed wrongly.
The first run (2026-09-23) scored 32/32 after one expectation correction, with
0 hazardous prompts routed to `answer`.

**Changes to `assistant.md` or `personality.md`** (or new knowledge that
changes answers) are reviewed with the answer review, which uses the
**local** prompt files and the live knowledge base, so it works before
merging:

```
AWS_PROFILE=OTS-Prod-Deploy python answers.py
```

It prints each answer with the passages it used (scores included, for
tuning `kb_min_score`). It flags broken mechanical rules: the "You could
also" count, invented numbers where the knowledge base has none, long
answers, and step-by-step wording. Tone and accuracy are for a person to
judge. It costs about $0.005 per case. The cases are in
`eval/answer_cases.json`.

## Knowledge base

Eddie's knowledge is written by employees on the website, not in this repo.
Terraform ([`aws/modules/chatbot/kb.tf`](aws/modules/chatbot/kb.tf)) creates
the **containers**, and the knowledge API (`modules/employees`, `kb.py`)
manages the **content**:

```
Add Knowledge (any employee): the form, or a chat with Herman ─► pending/<id>.json
    │  KBValidation (admins): edit, then approve or reject (with a reason)
    ├─ reject ─► rejected/<id>.json (deleted after 30 days)
    ▼  approve
approved/<type>/<slug>-<id>.md  in  ae-rv-chatbot-kb-docs-<account> (private, versioned)
    │  indexing job (started automatically on approve and remove)
    ▼
~300-token passages ─► Titan Text Embeddings V2 ─► S3 Vectors index
    │
Chat question ─► Retrieve the most relevant passages ─► the Answer step uses them
```

- **Only `approved/` is indexed.** The data source's `inclusion_prefixes`
  make that structural: drafts and rejections are never read.
- **Who can do what.** "Admin" means an employee in the Cognito `admins`
  group.
  - Any employee can submit, see their own submissions, and view or
    download everything on **KBViewer**.
  - Admins review on **KBValidation**, and can remove or re-index on
    KBViewer.
- **Behavior vs. knowledge:**
  - How Eddie talks (personality, safety rules, the "one more capability"
    rule) lives in `modules/chatbot/prompts/`. It deploys through Terraform,
    and a change needs the safety eval.
  - What he knows is managed on the site, takes effect a minute or two after
    approval, and involves no PR or deploy.
- **Never upload to the bucket by hand.** Use the site, so every file has
  the structure Eddie's prompts rely on.
- **The repo history** still contains the knowledge that lived in the old
  public `knowledge-base/` folder (removed 2026-09-24). New knowledge is
  never public.

### The three kinds of knowledge

The Add Knowledge page builds the Markdown from a guided form:

| Kind | Use it for | Markdown written |
|---|---|---|
| **Capability** | Something a customer can **do** with their RV, and what it takes | `# Capability: <title>`, then `## What it takes: <title>`, `## How A&E sets it up: <title>`, `## Also possible with this setup: <title>` |
| **FAQ** | Short questions customers ask, with short answers | `# Frequently asked questions: <topic>`, then `## Q: …` per question |
| **Note** | Rules of thumb, service tips, lessons learned | `# <title>`, then `## <title>: <heading>` per section |

- **Bedrock doesn't know the kinds.** Retrieval ranks passages by meaning.
- **The structure is what matters:**
  - `## Q:` headings match how customers phrase questions.
  - Eddie takes his single "You could also…" idea **only** from a section
    named "Also possible with this setup".
  - Every heading carries the topic, so a passage cut from the middle of a
    file still says what it's about.

**Writing tips** (also shown on the form):
- One topic per heading, in plain customer language.
- Put numbers in (watts, amp-hours, runtimes) with the conditions they
  depend on.
- **No step-by-step wiring or battery procedures.** Eddie won't give them
  anyway. Describe *what* is needed and *why*, and leave the *how* to a
  technician.
- No customer details, and no prices you don't want quoted.

### Removing, restoring, and checking knowledge

- **Remove:** KBViewer → Remove (admins). Indexing runs automatically.
- **Restore:** the bucket is versioned, and earlier versions are kept for a
  year. In the S3 console, turn on **Show versions** for the file, delete
  its delete marker, then KBViewer → Re-index.
- **Back up:** KBViewer → Download all (.zip).
- **Check what Eddie will find**, without using the chatbot (AWS console,
  us-west-2):
  1. Go to Bedrock → Knowledge Bases → `ae-rv-chatbot-kb` → Test knowledge
     base.
  2. Turn **off** "Generate responses".
  3. Ask a real customer question.

### Costs

- Embedding: Titan V2 costs about $0.02 per million tokens, so syncing a
  few hundred pages costs pennies.
- The S3 Vectors storage and queries for a library this size are well under
  $1 a month.

### Protection

- **The documents bucket:**
  - private (public access blocked)
  - encrypted and versioned
  - `prevent_destroy`, because it holds the owner's own writing
- **The vector store** is derived data: indexing rebuilds it from the
  bucket.
- **The knowledge API's role** can only touch the bucket's `pending/`,
  `rejected/`, and `approved/` prefixes and start or watch this knowledge
  base's indexing jobs.
- **The knowledge base's role** can only read the bucket, call Titan, and use
  its own index.

## Employees

A signed-in area for A&E's 3–4 employees (`modules/employees/`). The site's
`/employees/` page is a public shell. Everything behind it comes from an API
that only answers requests carrying a valid token from the employee user
pool, so nothing protected is in the site build.

```
Browser ─► /employees/ (public shell)
  └ "Sign in" ─► ae-rv-employees.auth.us-west-2.amazoncognito.com (Cognito managed login)
       └ back with tokens (authorization code + PKCE)
  └ GET <employees_api_url>/me   Authorization: Bearer <ID token>
       HTTP API ─ JWT authorizer (checks signature, issuer, audience, expiry) ─► Lambda ae-rv-employees-me
```

| Piece | Setting |
|---|---|
| User pool `ae-rv-employees` | Essentials tier (free up to 10,000 monthly users). Admin-created accounts only, no sign-up. Deletion protection + `prevent_destroy` |
| Sign-in | A password (14+ characters) or a **passkey** (fingerprint, face, or PIN, with user verification required) |
| MFA | **Required** (`ON`). A password sign-in needs an authenticator-app (TOTP) code. A passkey with user verification counts as both factors (`FactorConfiguration = MULTI_FACTOR_WITH_USER_VERIFICATION`). The AWS provider can't set that, and it can't turn MFA `ON` without it (Cognito rejects the combination). So `terraform_data.mfa_config` applies the whole MFA configuration with the AWS CLI during apply, from `local.mfa` in `cognito.tf`, and the pool resource ignores those three settings. The provider can't read them back, so a `check` block (`mfa_config_matches`) reads them with the AWS CLI on every plan and **warns** if they don't match `local.mfa`. The warning also appears in the PR plan comment. To fix drift: `terraform apply -replace=module.employees.terraform_data.mfa_config` |
| Email | Cognito's built-in email (50 a day): invites and password resets only. There's no SES, because only email sign-in codes would need it |
| Tokens | ID and access tokens last 60 minutes, and the refresh token 12 hours |
| `admins` group | For the Admin page (Phase 2). Its members see `"isAdmin": true` from `/me` |
| API | `GET /me` (any employee). **Admins only** (the `admins` group, checked by the function, 403 otherwise): `GET /admin/usage?days=N` (requests vs the daily quota, exchanges, conversations, routes, tokens, and estimated Bedrock cost per UTC day) and `GET /admin/conversations?days=N` (transcripts grouped by conversation ID, each with total tokens and cost), N = 1–30; `GET /admin/herman-usage?days=N` (Herman's usage, cost and response times, from his logs); `GET /admin/features` (each feature switch with its recent changes) and `POST /admin/features/{name}` `{"enabled": true\|false}` (the Feature Mgr page; see [Turning it on or off](#turning-it-on-or-off)). The admin function's role can list/read `transcripts/`, read the chat usage plan's usage, and read and overwrite only the parameters in `feature_flags`. Costs use `price_per_mtok_input`/`output` (Haiku 4.5: $1.10 / $5.50). **Knowledge** (`/kb/*`, function `ae-rv-employees-kb`): any employee can submit entries (`POST /kb/entries`), see their own (`GET /kb/entries/mine`) and view all live knowledge (`GET /kb/documents`). Admins review (`GET /kb/entries/pending`), approve with optional edits or reject with a reason (`POST /kb/entries/{id}/approve|reject`), remove (`DELETE /kb/documents/{id}`) and re-index (`POST /kb/sync`). Entries live in the documents bucket under `pending/`, `rejected/` (expire after 30 days) and `approved/`, the only prefix the data source indexes. **Herman** (`POST /assistant/chat` and `GET /assistant/status`, function `ae-rv-employees-assistant`): any employee, while his switch is on; see [Herman, the employee assistant](#herman-the-employee-assistant). Throttled to 2 requests a second (burst 5). CORS allows only aervsolutions.com, www, and localhost:4321 |

Employee email addresses live only in the user pool, never in this public
repo or in Terraform.

### Herman, the employee assistant

Herman is a chat assistant for employees only. He is separate from Eddie,
the public chatbot. His first job is teaching Eddie: he interviews an
employee, asks the right questions for the kind of knowledge (capability,
FAQ or note), and drafts the entry.

```
Employee (signed in) ─► POST /assistant/chat  {mode: "knowledge", messages, draft, seed?}
    HTTP API ─ JWT authorizer ─► Lambda ae-rv-employees-assistant ─► Bedrock (Claude Haiku 4.5)
    ◄─ {reply, draft, ready, missing, reviewNote}
Employee clicks "Submit for review" ─► POST /kb/entries {type, fields, origin: "chat", reviewNote}
    ─► pending/<id>.json ─► KBValidation (admins) ─► approved/ ─► Eddie
```

- **Why he's separate from Eddie.** Eddie's API is public: no sign-in, and
  its key ships in the site. Herman will later work with work orders,
  invoices and quotes, so he lives on the employee API. A request without a
  valid employee ID token is rejected with a 401 before any code runs.
  Herman and Eddie share the model, but no prompts or code.
- **He only drafts.**
  - His role can call the model and write his own logs, and nothing else.
    He has no access to the documents bucket.
  - The employee submits the draft through the same `POST /kb/entries` as
    the form. An admin still approves every entry before Eddie sees it.
  - `ready` is decided by the function, not the model: the draft must pass
    the same checks `POST /kb/entries` applies (`knowledge_fields.py`).
- **Who wrote it.** Every entry records its author (Cognito `sub` and
  email) from the verified token, never from the request, so neither Herman
  nor the browser can set it. Approval copies it into the published file's
  S3 metadata (`author-sub`, `author-email`), along with `origin` (`form`
  or `chat`).
  - None of this goes into the Markdown, which is what Eddie reads.
  - `reviewNote` is Herman's flag for the reviewer (hazardous work, prices,
    customer details). It's advisory: it travels through the browser, so an
    employee could remove it. The reviewer still reads the entry itself.
- **Coming from Eddie.** A `seed` carries a customer question, Eddie's reply
  and its `source` from a chat with Eddie. Herman starts the interview from
  that gap, and treats the seeded text as data, never instructions.
- **Modes.** Each of Herman's jobs is a `mode` in `lambda/herman.py`, with its
  own prompt, tool, and allowed Cognito groups. The function checks the
  groups, never the model. `knowledge` is open to every employee. Future
  modes add their own tools and IAM statements.
- **On/off switch.** Herman has his own switch, `/ae-rv/chatbot/herman/enabled`,
  created by this module as `true` and flipped on the **Feature Mgr** admin
  page like Eddie's.
  - He reads it on every request, so a flip takes effect at once.
  - When it's off, or can't be read, `POST /assistant/chat` answers 503
    "Herman is switched off right now" before any model call.
  - `GET /assistant/status` returns `{"enabled": …}` so the Herman tab can
    say so.
  - It doesn't affect Eddie, customers, or the Add Knowledge form.
- **Stateless.** Like Eddie, Herman keeps no conversation: the browser sends
  the conversation (up to 40 messages) and the current draft on every turn.
  Each chat turn logs one JSON line: the caller's `sub` and email, the mode,
  the model, token counts, `bedrockMs` (Bedrock's own processing time, from
  the `x-amzn-bedrock-invocation-latency` response header) and `totalMs` (the
  whole turn). It never logs content.
- **Usage on AI Stats.** `GET /admin/herman-usage?days=N` (admins, N = 1–30)
  runs one CloudWatch Logs Insights query over those lines and returns:
  - turns, employees, tokens and estimated cost, per day, per model and per
    employee;
  - how often he was switched off, and errors;
  - median and slowest response times.

  His logs are kept 30 days, so that's as far back as it goes.
  - **Costs:** priced per model from `HERMAN_PRICES`, the same Haiku rates as
    Eddie. A model with no price shows as unknown, never $0.
  - **Older lines:** those without a model count as the current one.
  - **Permissions:** the admin role can start queries on Herman's log group
    only.
- **Cost.** About half a cent per turn (Haiku). The API's shared throttle is
  2 requests a second.

**Prompts and tuning.** Herman's prompts are in
`aws/modules/employees/lambda/prompts/`:
- `herman_personality.md`: his own personality, separate from Eddie's.
- `intake.md`: the knowledge-mode rules.

Changing them never affects Eddie, so the chatbot's safety eval doesn't need
a rerun. Eddie's personality (`modules/chatbot/prompts/personality.md`) stays
Eddie's alone.

After changing Herman's prompts, or `herman.py`, run his eval. It plays
scripted employee conversations through the Lambda's own code with the
**local** prompts, and flags invented numbers, wrong kinds, missing reviewer
notes, prompt leaks and injection:

```bash
cd infrastructure/aws/modules/employees/eval
AWS_PROFILE=OTS-Prod-Deploy python intake_eval.py            # all cases, about $0.15
AWS_PROFILE=OTS-Prod-Deploy python intake_eval.py identity   # one case
```

### Runbook

Set these first (from `terraform -chdir=infrastructure/aws/live/prod output`):

```bash
POOL=$(terraform -chdir=infrastructure/aws/live/prod output -raw employees_user_pool_id)
EMAIL=employee@example.com
```

- **Add an employee.** Cognito emails them an invite with a temporary
  password (valid 7 days):
  ```bash
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" \
    --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL
  ```
- **Their first sign-in** (at aervsolutions.com/employees/ → Sign in):
  1. Email + temporary password, then choose a new password.
  2. Cognito makes them set up an authenticator app (scan the QR code) before
     finishing. MFA is required.
  3. Back on the Employees page, **Add a passkey**. From then on, they sign
     in with the passkey: enter their email, then choose the passkey option.
- **Make someone an admin:** `aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$EMAIL" --group-name admins`
  (they get it on their next sign-in).
- **Check an employee's MFA:** `aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$EMAIL"`.
  `UserMFASettingList` should include `SOFTWARE_TOKEN_MFA`.
- **Lost phone or passkey:** `aws cognito-idp admin-reset-user-password --user-pool-id "$POOL" --username "$EMAIL"`
  (they get a reset code by email). To also clear the authenticator app:
  `aws cognito-idp admin-set-user-mfa-preference --user-pool-id "$POOL" --username "$EMAIL" --software-token-mfa-settings Enabled=false,PreferredMfa=false`,
  then Cognito makes them set it up again on their next sign-in.
- **Remove an employee.** Sign them out everywhere, then delete them:
  ```bash
  aws cognito-idp admin-user-global-sign-out --user-pool-id "$POOL" --username "$EMAIL"
  aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL"
  ```
  An already-issued ID token keeps working until it expires (up to 60
  minutes).

### Local development

Put the `employees_*` outputs into `site/.env` as `PUBLIC_COGNITO_AUTHORITY`,
`PUBLIC_COGNITO_DOMAIN`, `PUBLIC_COGNITO_CLIENT_ID`, and
`PUBLIC_EMPLOYEE_API_URL`. `http://localhost:4321/employees/` is an allowed
callback, so sign-in works against the real pool.

### Not yet covered

- A native provider argument for `FactorConfiguration`
  ([hashicorp/terraform-provider-aws#47598](https://github.com/hashicorp/terraform-provider-aws/issues/47598),
  open PR #48388). Once it ships, move `local.mfa` back onto the pool
  resource, drop its `ignore_changes`, and remove `terraform_data.mfa_config`.
- A custom login domain. Pin the passkey relying party ID to the prefix
  domain first, or every passkey stops working.
- API access logs (the Lambda logs each call, by user ID).

## Deploying to AWS

`bootstrap` stays local/manual (run from your machine, once). Everything
else — `live/prod` applies and site deploys — runs in GitHub Actions from
here on.

1. **AWS credentials**: configure the AWS CLI with an `OTS-Prod-Deploy`
   named profile for the target account, region `us-west-2`
   (`aws configure --profile OTS-Prod-Deploy`). Terraform ≥ 1.9. For every
   `terraform` command below run from your machine (not CI), set
   `AWS_PROFILE=OTS-Prod-Deploy` in your shell first — both the provider
   and the `live/prod` S3 backend pick it up automatically from there.
   `bootstrap`'s provider block also defaults to this profile on its own
   (`var.profile`), but `live/prod`'s backend config can't reference
   Terraform variables, so it relies on the env var instead — deliberately
   not hardcoded in `backend.hcl`, since that file is shared with CI, which
   authenticates a different way (OIDC-assumed role, no named profile).
2. **Bootstrap the state backend and CI trust role** (local state, run
   once):
   ```
   cd infrastructure/aws/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # then set alert_email
   terraform init
   terraform apply
   ```
   `terraform.tfvars` is gitignored: it holds the owner-alert email address,
   which must never be committed to this public repo.

   This creates the S3 state bucket, a DynamoDB table, and two IAM roles
   assumed via OIDC, so no AWS access keys are ever stored as GitHub
   secrets:
   - `github-actions-terraform`: used by `terraform-aws.yml` to apply.
     Scoped to the `aws-infra` Environment.
   - `github-actions-terraform-plan`: used by `terraform-aws-plan.yml`.
     Read-only: it can read the prod state and write only its lock object,
     and it can read only the one Amplify app and hosted zone (the
     `amplify_app_id` / `hosted_zone_id` variables). Trusted for this repo's
     `pull_request` subject. Fork PRs never receive an OIDC token.

   If a CI plan fails with `AccessDenied` after a new resource type is
   added to `live/prod`, add the exact read action it names to the plan
   role's policy and re-apply `bootstrap` locally. Don't widen it to a
   wildcard.

   Note: the DynamoDB table is **no longer used**. `live/prod`'s backend
   now uses S3's native locking (`use_lockfile = true`, Terraform ≥ 1.10),
   which writes a `.tflock` object beside the state file and replaces the
   deprecated `dynamodb_table` backend parameter. The table resource is
   still in `bootstrap` so switching locking mechanisms didn't destroy
   infrastructure in the same change; it can be removed in a later pass.
3. Fill in `infrastructure/aws/live/prod/backend.hcl` with the
   `state_bucket_name` output from step 2 (no lock table needed).
4. **Create the GitHub Environment** `aws-infra` (repo Settings →
   Environments → New environment). This is what the IAM role's trust
   policy is scoped to — only a job that declares
   `environment: aws-infra` can assume it. Optionally add a required
   reviewer here for a manual approval gate before `terraform apply` runs.
   Also create `chatbot-toggle`, which the chatbot toggle role is scoped to
   the same way.
5. **Add a repo variable** (Settings → Secrets and variables → Actions →
   Variables) named `AWS_TERRAFORM_ROLE_ARN`, set to the
   `github_actions_role_arn` output from step 2, and one named
   `AWS_TERRAFORM_PLAN_ROLE_ARN`, set to the `github_actions_plan_role_arn`
   output, and one named `AWS_CHATBOT_TOGGLE_ROLE_ARN`, set to the
   `github_actions_chatbot_toggle_role_arn` output.
6. **Generate a GitHub token for Amplify** and add it as a repo secret.
   Confirmed by a real `terraform apply` failure (`BadRequestException:
   You should at least provide one valid token`): the Amplify `CreateApp`
   API always needs an explicit token — authorizing the AWS Amplify GitHub
   App in the console does **not** carry over to an API/Terraform-driven
   app creation, only to app creation started from within the console's
   own browser session. So:
   - GitHub → Settings → Developer settings → Personal access tokens →
     Tokens (classic) → Generate new token. Scopes: `repo` (full) and
     `admin:repo_hook`.
   - `gh secret set AMPLIFY_GITHUB_TOKEN --body "<the token>"` (or add it
     manually under repo Settings → Secrets and variables → Actions →
     Secrets — note **Secrets**, not the **Variables** tab used in step 5).
   - `terraform-aws.yml` passes it to `terraform apply` as
     `TF_VAR_github_access_token`.
7. **Provision hosting**: open a PR that touches
   `infrastructure/aws/live/**` and merge it. `terraform-aws.yml` runs and
   applies — this creates the real Amplify app.
8. **Wire up the site deploy trigger** (one time):
   ```
   terraform -chdir=infrastructure/aws/live/prod output -raw webhook_url
   gh secret set AMPLIFY_WEBHOOK_URL --body "<value from above>"
   ```
9. **Verify**: merge a PR touching `site/` and confirm `deploy-site.yml`
   runs its `deploy-aws` job, and the site goes live at
   `terraform -chdir=infrastructure/aws/live/prod output -raw site_url`.
   Merge a PR touching only `infrastructure/aws/**` and confirm only
   `terraform-aws.yml` runs — `deploy-site.yml` does not.

**Running any of this locally** (not through CI) also needs the token:
`TF_VAR_github_access_token=<token> terraform apply` (or `-var
github_access_token=<token>`) — never commit a real value anywhere in this
repo.

## Deploying to Azure

1. **Azure credentials**: `az login` with the target subscription
   selected (`az account set --subscription <id>` if needed), region
   `West US 2`. Terraform ≥ 1.9. No stored service principal — the
   `azurerm` provider uses your local Azure CLI session, same pattern as
   the AWS provider using your local AWS CLI credentials.
2. **Bootstrap the state backend** (local state, run once):
   ```
   cd infrastructure/azure/bootstrap
   terraform init
   terraform apply
   ```
3. Fill in `infrastructure/azure/live/prod/backend.hcl` with the
   `resource_group_name`, `storage_account_name`, and `container_name`
   outputs from step 2.
4. **Provision hosting**:
   ```
   cd infrastructure/azure/live/prod
   terraform init -backend-config=backend.hcl
   terraform plan
   terraform apply
   ```
5. **Wire up the deploy trigger** (one time):
   ```
   terraform output -raw deployment_token
   gh secret set AZURE_STATIC_WEB_APPS_API_TOKEN --body "<value from above>"
   ```
6. **Turn Azure on** in [`deploy-targets.yml`](deploy-targets.yml) by
   setting `azure: true`. Until that flag flips, `deploy-site.yml` skips
   its `deploy-azure` job entirely — the secret alone doesn't enable
   deploys.
7. **Verify**: push a change under `site/` to `main` and confirm
   `deploy-site.yml` runs its `deploy-azure` job and the Static Web App
   builds/deploys. Push a change touching only `infrastructure/**` and
   confirm the workflow does not run.

## Switching clouds later

Apply the other stack following its steps above, set its deploy secret, and
flip its flag to `true` in [`deploy-targets.yml`](deploy-targets.yml). Both
clouds can be `true` at once if you want to run them side by side during a
migration.

Once you've confirmed the new one is serving traffic correctly, set the old
one's flag back to `false` — that alone stops its deploys, with no workflow
edits. Then optionally `terraform destroy` the stack you're leaving (from
its `live/prod` directory) and remove its now-unused GitHub secret.
