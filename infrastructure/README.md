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

Two GitHub Actions workflows, gated to different paths so neither fires for
the wrong kind of change:

| Workflow | Triggers on a push to `main` touching... | What it does |
|---|---|---|
| `terraform-aws-plan.yml` | Every PR to `main` (plans only when `infrastructure/aws/**` changed) | `fmt -check`, `validate`, and `terraform plan` for `live/prod` using a read-only role, posted as a PR comment. Required check: a failing plan blocks the merge |
| `terraform-aws.yml` | `infrastructure/aws/live/**`, `infrastructure/aws/modules/**` (on merged PR) | Runs `terraform apply` against AWS, authenticated via OIDC (no stored keys) |
| `deploy-site.yml` | `site/**` | Reads [`deploy-targets.yml`](deploy-targets.yml), then deploys to each cloud whose flag is `true` |

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
   terraform init
   terraform apply
   ```
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
5. **Add a repo variable** (Settings → Secrets and variables → Actions →
   Variables) named `AWS_TERRAFORM_ROLE_ARN`, set to the
   `github_actions_role_arn` output from step 2, and one named
   `AWS_TERRAFORM_PLAN_ROLE_ARN`, set to the `github_actions_plan_role_arn`
   output.
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
