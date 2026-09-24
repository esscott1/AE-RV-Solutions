# Plan: Employee sign-in + Admin page

**Status:** active. Approved 2026-09-24; replaces the deferred 2026-09-23 plan.
Phase 1 is in progress.

**Found while building PR 1** (these override the tables below):
- AWS provider 6.66 (the newest release) has no `FactorConfiguration`
  setting. PR 1 shipped **MFA `OPTIONAL`** as a fallback. The first real
  sign-in showed the fallback fails: with `SINGLE_FACTOR` (Cognito's
  default), a user with an authenticator app is never offered passkey
  sign-in. The fix (2026-09-24, owner's choice): **MFA `ON`**, with
  `MULTI_FACTOR_WITH_USER_VERIFICATION` set by the AWS CLI from a
  `terraform_data` provisioner that reruns whenever the pool's MFA or
  passkey settings change.
- The passkey relying party ID is **not pinned**. The pool is created
  before its domain exists, so pinning would need a second apply. The
  default is the prefix domain. Pin it before adding a custom domain.
- The HTTP API has **no access logs**: they need account-wide CloudWatch
  Logs delivery permissions for CI. The Lambda logs each call instead.

## Context
The deferred employee sign-in plan (2026-09-23) comes off the shelf. The goal:
a secure place where 3–4 employees sign in and see sensitive information.
Afterwards, an **Admin page** gets two sections:
- **AI usage** for Eddie
- **Add knowledge** for Eddie's knowledge base

The order is fixed: the **hamburger menu + authentication ship and are validated
first (Phase 1)**. The Admin page comes second (Phase 2).

The deferred plan predates the chatbot. The review below compares it against
the Terraform that exists today. The first implementation step is rewriting
`docs/plans/employee-sign-in.md` with this plan.

**Decisions (2026-09-24):**
- **Sign-in is password + passkey, with no SES.**
  - Cognito's built-in email sends the invite with a temporary password.
  - On first sign-in, the employee sets a password and enrolls an authenticator app (TOTP).
  - They then add a passkey (fingerprint, face, or PIN) and use it day to day.
  - MFA is **required**: a password sign-in needs the authenticator code, and a passkey with user verification counts as MFA by itself.
  - Email sign-in codes were dropped, because they're the one email type Cognito can't send without SES.
- The Admin page is for a Cognito **`admins` group** only, checked on the server.
- Employee knowledge entries are **drafts until an admin approves** them.
- Entries are stored in **private S3 only**, never in the public repo.
- AI usage shows **totals and recent chat transcripts**. Transcripts are
  kept for 30 days, and the chat widget shows a notice that chats are stored.

## Terraform review: what changes vs the deferred plan
| # | Finding in today's Terraform | Plan change |
|---|---|---|
| 1 | CI roles are scoped by **name prefix**, one bootstrap file per feature (`bootstrap/chatbot.tf`, `chatbot_kb.tf`), with a `chatbot_name_prefix` variable | New `bootstrap/employees.tf` + variable `employees_name_prefix = "ae-rv-employees"`. It follows the same statement layout (Manage*/Read*/DescribeOnly), and the plan role gets matching read-only actions |
| 2 | API Gateway permissions cover only REST paths (`/restapis`, `/usageplans`, `/apikeys`) | An HTTP API needs **`/apis` and `/apis/*`** (+ `/tags/*`) in both roles |
| 3 | There are **no Lambdas** yet, and `live/prod/versions.tf` has only the `aws` provider | Add the **`hashicorp/archive`** provider (`archive_file` zips `modules/employees/lambda/`). Both roles get `lambda:*Function*`, `GetPolicy`, `ListVersionsByFunction`, and `GetFunctionCodeSigningConfig`, scoped to `function:ae-rv-employees-*`. PassRole is limited to `lambda.amazonaws.com` for `role/ae-rv-employees-*` |
| 4 | There is **no SES**, and `live/prod/main.tf` says "no aws_route53_record resources belong here" | **No SES, no DNS records.** Sign-in is password + passkey (decided 2026-09-24), so Cognito's built-in email is enough: 50 emails a day per account, covering invites and forgotten-password codes. Only email sign-in codes would need SES. Nothing changes in `live/prod/main.tf`'s Route 53 comment |
| 5 | Personal emails stay out of the public repo (the alert-email rule) | **Employees are never in Terraform.** They're added and removed with CLI commands from a runbook, and their addresses live only in Cognito |
| 6 | Amplify `environment_variables` in `live/prod/main.tf` already carry `PUBLIC_CHAT_*` | Merge in `PUBLIC_COGNITO_DOMAIN`, `PUBLIC_COGNITO_CLIENT_ID`, and `PUBLIC_EMPLOYEE_API_URL`. These are public identifiers |
| 7 | Every stateful resource has `prevent_destroy` | The user pool gets `prevent_destroy` + `deletion_protection = "ACTIVE"`. The Phase 2 entries bucket gets `prevent_destroy` + versioning |
| 8 | The knowledge-base sync runs `aws s3 sync knowledge-base/ … --delete` into `ae-rv-chatbot-kb-docs-*` | Employee entries **must not** go into that bucket, because the next repo sync would delete them. Phase 2 uses a **separate entries bucket as a second data source** on the same knowledge base. The existing sync is untouched |
| 9 | State machine logging is `ERROR` level with `include_execution_data = false`. Nothing records routes or chats | Phase 2 adds a **Record** step that writes each exchange to DynamoDB with a 30-day TTL. The chatbot's bootstrap permissions gain DynamoDB on `table/ae-rv-chatbot-*` |
| 10 | The chat API is a REST API with an API key + usage plan (50/day) | Admin usage reads that usage plan (`apigateway:GET /usageplans/*/usage`). The employee API stays **separate** (HTTP API + JWT), so it doesn't share the public key or quota |
| 11 | Tagging is per module: `module "chatbot"` gets `tags = { Customer = "AERVSolutions" }`, and the zone is tagged the same way | **Every taggable resource in this plan carries `Customer = "AERVSolutions"`.** That covers the user pool, HTTP API + stage, Lambdas, IAM roles, log groups, the DynamoDB table, the entries bucket, and the data source where supported. `modules/employees` takes a `tags` variable (as `modules/chatbot` does), which `live/prod` passes in. Chatbot additions (DynamoDB, entries bucket) use the existing `var.tags`. Some resources the API can't tag: the Cognito app client, domain, group, and branding, Route 53 records, and IAM inline policies. Both CI roles get the tagging actions for each service (`cognito-idp:TagResource`/`ListTagsForResource`, `lambda:TagResource`/`ListTags`, `dynamodb:TagResource`/`ListTagsOfResource`, `s3:PutBucketTagging`, logs and `/tags/*`). **Verify:** each PR's plan shows the tag on every new taggable resource, and after apply, `aws resourcegroupstaggingapi get-resources --tag-filters Key=Customer,Values=AERVSolutions` lists them |

## Phase 1: Menu + sign-in (PR 1 Cognito/API → PR 2 site; each needs the owner's OK to merge)

**First commit** (on the PR 1 branch): replace `docs/plans/employee-sign-in.md` with this plan, marked "active".

### Step 0: Verified 2026-09-24 against AWS and Terraform provider docs
| Question | Answer | Effect on the plan |
|---|---|---|
| Do email sign-in codes need SES? | **Yes.** The docs footnote for email OTP says: "Requires Essentials feature plan or higher and Amazon SES email configuration." The built-in email (**50 a day per account, can't be raised**) covers invites, forgotten-password codes, and verification only | Email codes were dropped. Built-in email (`COGNITO_DEFAULT`) covers the invite and password reset. At 20 sign-ins a month, passkey sign-ins send no email at all |
| Password + passkey only? | Supported: "enroll a biometric device after they first sign in with a password." A passkey can only be registered after a first sign-in | `allowed_first_auth_factors = ["PASSWORD","WEB_AUTHN"]` |
| Passkeys with MFA required? | "Passkey authentication with user verification can satisfy MFA requirements when … `FactorConfiguration` [is] `MULTI_FACTOR_WITH_USER_VERIFICATION`" | MFA `ON` with authenticator app (TOTP) only; `user_verification = "required"` + that factor configuration. **Check that provider 6.66 exposes `FactorConfiguration`** (grep the provider schema). If it doesn't, fall back to MFA `OPTIONAL`, with the runbook requiring every employee to enroll TOTP, and raise it when the provider catches up |
| Passkey registration | Managed login doesn't prompt for one. After a first sign-in, send the user to `https://<domain>/passkeys/add?client_id=…&redirect_uri=…` | The Employees page gets an **"Add a passkey"** button |
| Relying party ID | Defaults to the prefix domain, and changing it later invalidates every passkey | **Pin** `relying_party_id = "ae-rv-employees.auth.us-west-2.amazoncognito.com"` |
| Managed login v2 | `managed_login_version = 2` alone shows no pages; a branding style is **required** via the API | Add `aws_cognito_managed_login_branding` with `use_cognito_provided_values = true` |
| Price | Essentials is free up to 10,000 monthly active users; managed login and built-in email have no charge | $0 |
| Bedrock metrics | `AWS/Bedrock` `Invocations`, `InputTokenCount`, `OutputTokenCount`, `InvocationThrottles`, with `ModelId` = the **inference profile ID** | Phase 2 usage reads these (confirm the live dimension first) |
| Knowledge base sources | Up to 5 data sources per knowledge base; `inclusion_prefixes` allows **one** prefix; a sync touches only its own source | The Phase 2 entries data source uses `approved/` |

**Still to run live** (the AWS SSO session had expired; run `aws sso login --profile OTS-Prod-Deploy` first):
- `aws cognito-idp describe-user-pool-domain --domain ae-rv-employees` (an empty result means the prefix is free)
- `aws cloudwatch list-metrics --namespace AWS/Bedrock` (the ModelId value, for Phase 2)

### PR 1: Cognito + protected API (Terraform)
- **`bootstrap/employees.tf`** (applied locally with the owner's OK before PR 1's CI plan): the permissions in findings 1–3 and 11, scoped to `ae-rv-employees-*`. The apply role gets `cognito-idp` on `userpool/*` (pool ARNs use generated IDs, so they can't be scoped by name; like the knowledge base, this account has only this pool). The plan role gets `DescribeUserPool`, `DescribeUserPoolClient`, `DescribeUserPoolDomain`, `GetUserPoolMfaConfig`, `ListTagsForResource`, `GetGroup`, and `DescribeManagedLoginBranding*`.
- **New module `modules/employees/`**:
  - `cognito.tf`:
    - User pool `ae-rv-employees`:
      - `ESSENTIALS` tier, email username, admin-create only
      - `allowed_first_auth_factors = ["PASSWORD","WEB_AUTHN"]`
      - `web_authn_configuration { relying_party_id = <prefix domain>, user_verification = "required" }` (+ `MULTI_FACTOR_WITH_USER_VERIFICATION`, see Step 0)
      - `mfa_configuration = "ON"` with `software_token_mfa_configuration { enabled = true }` (authenticator app; no SMS)
      - Password policy: 14+ characters, all character classes, temporary password valid 7 days
      - `email_configuration { email_sending_account = "COGNITO_DEFAULT" }`; account recovery by verified email only
      - An invite message template (`admin_create_user_config.invite_message_template`) linking to `https://aervsolutions.com/employees/`
      - Deletion protection and `prevent_destroy`
    - Prefix domain with `managed_login_version = 2` + `aws_cognito_managed_login_branding` (`use_cognito_provided_values = true`).
    - Public PKCE app client with callbacks and logouts for apex, www, and `localhost:4321` at `/employees/`, `ALLOW_USER_AUTH` + refresh, and `prevent_user_existence_errors`.
    - The **`admins` user group** (unused until Phase 2, but it exists from day one).
  - `api.tf`:
    - HTTP API `ae-rv-employees` with a JWT authorizer (issuer = the pool, audience = the client ID).
    - `GET /me` returns `{email, groups, content}`, with the Employees' Space heading coming from the API.
    - CORS for prod, www, and localhost. Throttling (rate 2, burst 5). Access logs with 30-day retention.
  - `lambda/me.py` + `lambda.tf`: Python 3.13, a log-only role, 30-day logs. It reads the claims the authorizer passes (`email`, `cognito:groups`) and never re-validates the token itself.
  - Outputs: the pool ID, client ID, domain, issuer, and API URL.
- **`live/prod/`**: `module "employees"` (with `tags`) + the env vars from finding 6, plus outputs.
- **Docs:** an "Employees" section in `infrastructure/README.md` with a runbook, plus a brief guardrail line in the root README and a CLAUDE.md module note. The runbook covers:
  - **Add an employee:** `admin-create-user` with `email_verified=true`. The invite with a temporary password is emailed by Cognito.
  - **Make someone an admin:** `admin-add-user-to-group admins`.
  - **Remove someone:** `admin-user-global-sign-out` + `admin-delete-user`.
  - **First sign-in:** temporary password → new password → scan the authenticator QR code → "Add a passkey".
  - **Lost phone or passkey:** `admin-reset-user-password` + `admin-set-user-mfa-preference`.
- **Verify:**
  - The CI plan is additions only.
  - After merge, create a test user (you, on your email) and complete the first sign-in in the browser.
  - `GET /me` returns **401 without a token** and **200 with one**, and a forged or expired token gets 401.

### PR 2: Hamburger menu + pages (site)
- **`SiteNav.astro`** (static + a small script, not React): top-right hamburger with Home, Testimonials, and Employees. `aria-expanded`, Esc/outside-click close it, `aria-current`, 44px tap target, existing tokens. `BaseLayout.astro` renders it and the Footer (moved out of `index.astro`).
- **`pages/testimonials.astro`**: h1 "Customer Testimonials".
- **`pages/employees.astro`**: a `noindex` public shell + the **`EmployeeSignIn.jsx`** island (sibling `EmployeeSignIn.css`, `.employee-sign-in__` classes, per CLAUDE.md):
  - It uses `oidc-client-ts` (auth code + PKCE), with tokens in sessionStorage.
  - It shows the heading/content **from `GET /me`**, so nothing sensitive is in the build.
  - Sign-out goes through Cognito's logout endpoint.
  - An **"Add a passkey"** button links to the managed login `/passkeys/add` page and returns to `/employees/`.
- **`src/lib/api.js`**: `getEmployeeMe(token)`, which fails closed like `getChatStatus()`.
- `robots.txt`: `Disallow: /employees/`.
- **Verify:** `npm run check` + build; local sign-in against prod Cognito (localhost callback); the live site after deploy: menu on phone and desktop, sign-in, sign-out, and back-button after sign-out shows the shell only.

### Phase 1 exit criteria (the owner validates before Phase 2 starts)
Every employee can sign in (password + authenticator the first time, then
passkey). Someone not added by an admin can't sign up or sign in. An admin's `/me` shows `groups: ["admins"]`.

## Phase 2: Admin page (after Phase 1 is validated)

### PR 3: Chat transcripts + usage data (chatbot Terraform + widget)
- **`modules/chatbot/transcripts.tf`**: DynamoDB `ae-rv-chatbot-transcripts` (on-demand, TTL 30 days, encrypted, PITR off). Key: `day` (YYYY-MM-DD) + `ts#executionId`, so "last N days" is a cheap Query, not a Scan.
- **State machine:** a final `Record` task (`dynamodb:putItem` optimized integration) after every reply state: the last customer message, the reply, the route (answer/safety_referral/emergency/decline/unavailable/offline), the source label, and the token counts from the Answer/Classify results. **No IP or identifiers.** Errors are caught, so a failed write never breaks a chat. The Step Functions role gets `dynamodb:PutItem` on that table only.
- Widget: a one-line notice ("Chats are stored for 30 days to improve our answers. Please don't share personal details.").
- Rerun the safety eval (the route logic changes around it) and `answers.py`.

### PR 4: Admin page + knowledge entries
- **`modules/chatbot/kb.tf`**:
  - Entries bucket `ae-rv-chatbot-kb-entries-<acct>` (private, versioned, `prevent_destroy`) with `pending/` and `approved/` prefixes.
  - A **second data source** with `inclusion_prefixes = ["approved/"]`, so drafts are never indexed.
  - The knowledge base role can read the bucket.
  - Bootstrap gets the matching bucket ARN.
- **`modules/employees/` admin routes**: the JWT authorizer + a Lambda check that `cognito:groups` contains `admins` (403 otherwise):
  - `GET /admin/usage?days=7`:
    - The usage plan's daily counts vs the 50/day quota.
    - `AWS/Bedrock` metrics for tokens + a computed estimated cost ($1.10/$5.50 per 1M tokens, set as variables; no Cost Explorer, which is charged per call).
    - Route counts and **recent transcripts** from DynamoDB.
  - `GET/POST /admin/entries`: any **employee** can submit a Markdown entry (title + body, size-limited, saved to `pending/<id>.md` with the author email in object metadata).
  - `POST /admin/entries/{id}/approve|reject`: **admins only**. Approve copies the entry to `approved/` and starts an ingestion job on the entries data source. Reject deletes the draft.
  - `DELETE /admin/entries/{id}`: admins only. It removes the approved entry and re-syncs.
- **Site:** `pages/admin.astro` (noindex shell) + the `AdminPanel.jsx` island (with `AdminPanel.css`) with **Usage** (totals, a small daily chart, a transcript list) and **Knowledge** (submit form, pending queue with Approve/Reject, approved list). Add the menu item "Admin", shown only when `/me` says admin; the API enforces the real check.
- **Guardrails:**
  - Entries are indexed only after approval.
  - Eddie's safety rules still win over any document.
  - After approving, the owner reruns `answers.py` or tests an approved entry's topic in the widget.
  - No step-by-step hazardous content, and the entry form reminds submitters of that.

## Costs
- Cognito Essentials at ~4 users: free (10,000 monthly active users free).
- Lambda, the HTTP API, and DynamoDB at this volume cost pennies a month.
- Email: Cognito's built-in email, free (invites and password resets only).

## Out of scope
- A custom login domain
- Federated sign-in
- Custom branding
- Real sensitive-content storage beyond `/me` (next step: a private bucket + presigned URLs via the same API)
- Editing entries in place (reject and resubmit instead)
- Telegram
