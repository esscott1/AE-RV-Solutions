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
| `chatbot-kb-sync.yml` | `knowledge-base/**` (on merge to `main`), or manually from Actions → "Chatbot knowledge base sync" | Mirrors `knowledge-base/` into the knowledge base's S3 bucket and re-indexes it; reports indexed and failed counts (see [Knowledge base](#knowledge-base)) |

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

- **Normally:** the Actions tab → **Chatbot on/off** → Run workflow → `on`
  or `off`. It works from the GitHub mobile app, and the run history is the
  audit log.
- **Fallback:** `aws ssm put-parameter --name /ae-rv/chatbot/enabled --value
  false --overwrite` (or edit the parameter in the console, under Systems
  Manager → Parameter Store).

The API enforces the flag on every request, so switching it off also stops
bots that call the API directly without loading the site. Off costs nothing:
the state machine stops before any Bedrock call. Terraform creates the flag
as `false` and ignores its value afterwards, so an apply never undoes a
toggle.

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
- No conversation is stored, and Step Functions logs errors only, without
  execution data.

None of this stops a patient, human-paced extractor. It makes bulk
extraction slow, capped, and noisy. This matters most once v2 adds a
knowledge base: design it to return short grounded answers, never whole
documents or raw chunks.

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

The chatbot's knowledge comes from the owner's own FAQs, notes,
"capability" pages, and descriptions of diagrams, kept in the top-level
[`knowledge-base/`](../knowledge-base) folder. Terraform
([`aws/modules/chatbot/kb.tf`](aws/modules/chatbot/kb.tf)) creates the
**containers**; **merging a change to that folder publishes it**:

```
knowledge-base/ ─merge to main─► chatbot-kb-sync.yml
    │  aws s3 sync --delete (exact mirror)
    ▼
S3 bucket ae-rv-chatbot-kb-docs-<account> (private, versioned)
    │  Bedrock ingestion job
    ▼
split into ~300-token passages ─► Titan Text Embeddings V2 ─► S3 Vectors index
    │
Chat question ─► Retrieve the most relevant passages ─► the Answer step uses them
```

**Behavior vs. knowledge:** both are in the repo, reviewed in PRs, and
published by merging. They differ in what a change needs:
- **How the bot talks** (personality, safety rules, the "one more
  capability" rule) lives in `modules/chatbot/prompts/`. It deploys through
  Terraform, and a change needs the safety eval.
- **What it knows** lives in `knowledge-base/`. It deploys through the sync
  workflow in a couple of minutes, with no Terraform involved.

**Public repo:** the owner chose to keep the content here, so it's publicly
readable on GitHub. The chatbot's anti-distillation controls still limit
automated use of the chatbot (the quota, the decline route, short answers),
but they don't make the content secret.

### What to write, and in what format

| Content | Format | Folder in `knowledge-base/` |
|---|---|---|
| FAQs | Markdown (`.md`): `## Q: …` then the answer, many per file | `faq/` |
| "How do I…" capabilities | Markdown, one per file, **including one "Also possible with this setup" pairing** | `capabilities/` |
| Notes | Markdown with `#`/`##` headings (`.txt`, `.docx`, and `.pdf` also work) | `notes/` |
| Diagrams | The diagram file **plus a `.md` description beside it, with the same name** | `diagrams/` |

- Templates live in [`aws/modules/chatbot/kb-templates/`](aws/modules/chatbot/kb-templates),
  outside `knowledge-base/`, so they're never indexed.
- Markdown is plain text with `#` headings; any editor, even Notepad, works.
- Diagrams need the description because the knowledge base searches text.
  It can't interpret a picture.
- `README.md` files are never uploaded.

### Step by step

1. **Add or edit files** under `knowledge-base/` on a branch, and open a PR.
   Neither the site build nor the Terraform plan runs for this folder, so
   the checks finish in seconds.
2. **Merge** (owner's OK). The **Chatbot knowledge base sync** workflow runs
   automatically. After a minute or two, its summary shows how many
   documents were indexed, updated, removed, or failed.
3. **Check what it finds, without using the chatbot** (AWS console,
   us-west-2):
   1. **Bedrock → Knowledge Bases → `ae-rv-chatbot-kb` → Test knowledge
      base**.
   2. Turn **off** "Generate responses", so it only retrieves; that's
      almost free.
   3. Ask a real customer question. The passages shown are what the chatbot
      would get.
4. **Re-sync without a change** (e.g. after a failed run): Actions →
   **Chatbot knowledge base sync** → Run workflow.

**Don't upload to the S3 bucket by hand.** The sync mirrors `knowledge-base/`
exactly, so hand-uploaded files are deleted on the next run. The bucket is
versioned, so anything removed by mistake can still be recovered (**Show
versions** in the S3 console).

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
- **The vector store** is derived data: a sync rebuilds it from the bucket.
- **The sync role** can only write that one bucket and start and watch
  ingestion jobs.
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
| MFA | **Required** (`ON`). A password sign-in needs an authenticator-app (TOTP) code. A passkey with user verification counts as both factors (`FactorConfiguration = MULTI_FACTOR_WITH_USER_VERIFICATION`). The AWS provider can't set that yet, so `terraform_data.passkey_counts_as_mfa` sets it with the AWS CLI during apply. Without it, Cognito hides the passkey option from anyone who has MFA. Check it with `aws cognito-idp get-user-pool-mfa-config --user-pool-id "$POOL"` |
| Email | Cognito's built-in email (50 a day): invites and password resets only. There's no SES, because only email sign-in codes would need it |
| Tokens | ID and access tokens last 60 minutes, and the refresh token 12 hours |
| `admins` group | For the Admin page (Phase 2). Its members see `"isAdmin": true` from `/me` |
| API | `GET /me` only. Throttled to 2 requests a second (burst 5). CORS allows only aervsolutions.com, www, and localhost:4321 |

Employee email addresses live only in the user pool, never in this public
repo or in Terraform.

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

- A native provider argument for `FactorConfiguration`. Replace
  `terraform_data.passkey_counts_as_mfa` when the AWS provider adds one.
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
   Also create `chatbot-toggle` and `chatbot-kb-sync`, which the chatbot
   toggle and knowledge-base sync roles are scoped to the same way.
5. **Add a repo variable** (Settings → Secrets and variables → Actions →
   Variables) named `AWS_TERRAFORM_ROLE_ARN`, set to the
   `github_actions_role_arn` output from step 2, and one named
   `AWS_TERRAFORM_PLAN_ROLE_ARN`, set to the `github_actions_plan_role_arn`
   output, one named `AWS_CHATBOT_TOGGLE_ROLE_ARN`, set to the
   `github_actions_chatbot_toggle_role_arn` output, and one named
   `AWS_CHATBOT_KB_SYNC_ROLE_ARN`, set to the
   `github_actions_chatbot_kb_sync_role_arn` output.
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
