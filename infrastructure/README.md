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
`infrastructure/`, in the same repo. Whichever cloud you use, a push to
`main` that only touches `infrastructure/**` must **never** trigger a
rebuild/redeploy of the site. Both `.github/workflows/deploy-*.yml`
workflows are gated with `paths-ignore: ["infrastructure/**"]`, so that's
enforced the same way regardless of cloud.

- **AWS**: Amplify's own push trigger (`enable_auto_build`) is disabled
  entirely — its documented "monorepo app root" build-trigger filtering has
  multiple open bug reports of triggering builds on every commit regardless
  of path (see `aws/modules/amplify/main.tf`). `deploy-aws.yml` POSTs to an
  Amplify webhook instead.
- **Azure**: Static Web Apps' Terraform resource doesn't take a GitHub
  connection at all — deployment is *only* ever driven by a CI workflow
  using a deploy token, so there's no separate native trigger to disable.
  `deploy-azure.yml` runs the official `Azure/static-web-apps-deploy`
  action.

Both workflow files always exist; only the one whose secret you've set
actually deploys (each has a no-op guard step). That's what makes "pick one
cloud" work without deleting the other's workflow.

## Where each piece of automation runs

Three separate GitHub Actions workflows exist for AWS, each gated to a
different set of changed paths so they never fire for the wrong kind of
change:

| Workflow | Triggers on a merged PR touching... | What it does |
|---|---|---|
| `terraform-aws.yml` | `infrastructure/aws/live/**`, `infrastructure/aws/modules/**` | Runs `terraform apply` against AWS, authenticated via OIDC (no stored keys) |
| `deploy-site.yml` | `site/**` | Reads [`deploy-targets.yml`](deploy-targets.yml) and confirms AWS is a configured target (currently a no-op confirmation — see below) |
| `deploy-aws.yml` | any push to `main` except `infrastructure/**` | POSTs to the Amplify webhook — this is the actual site deploy trigger |

`infrastructure/aws/bootstrap/**` deliberately isn't in `terraform-aws.yml`'s
path filter — `bootstrap` stays a local, one-time step (see below), since
it creates the very state backend and CI trust role that `terraform-aws.yml`
depends on.

`deploy-targets.yml` is meant to eventually control which cloud(s) the site
deploys to, but only its `aws` key is read anywhere today — `azure: false`
is inert, reserved for when Azure's site-deploy path is built out.
`deploy-site.yml`'s AWS job is a confirmation step, not a second deploy
path: the real deploy already happens via `deploy-aws.yml`'s webhook call
on the same merge (not Amplify's native build trigger, which is disabled —
see above).

## Deploying to AWS

`bootstrap` stays local/manual (run from your machine, once). Everything
else — `live/prod` applies and site deploys — runs in GitHub Actions from
here on.

1. **AWS credentials**: configure the AWS CLI with an `OTS-Prod-Deploy`
   named profile for the target account, region `us-west-2`
   (`aws configure --profile OTS-Prod-Deploy`). Terraform ≥ 1.9.
2. **Bootstrap the state backend and CI trust role** (local state, run
   once):
   ```
   cd infrastructure/aws/bootstrap
   terraform init
   terraform apply
   ```
   This creates the S3 state bucket, the DynamoDB lock table, and an IAM
   role (`github-actions-terraform`) that `terraform-aws.yml` assumes via
   OIDC — no AWS access keys are ever stored as GitHub secrets.
3. Fill in `infrastructure/aws/live/prod/backend.hcl` with the
   `state_bucket_name` and `lock_table_name` outputs from step 2.
4. **Create the GitHub Environment** `aws-infra` (repo Settings →
   Environments → New environment). This is what the IAM role's trust
   policy is scoped to — only a job that declares
   `environment: aws-infra` can assume it. Optionally add a required
   reviewer here for a manual approval gate before `terraform apply` runs.
5. **Add a repo variable** (Settings → Secrets and variables → Actions →
   Variables) named `AWS_TERRAFORM_ROLE_ARN`, set to the
   `github_actions_role_arn` output from step 2.
6. **One-time: authorize the Amplify GitHub App.** In the AWS Amplify
   console, start "New app → Host web app → GitHub" and authorize the AWS
   Amplify GitHub App for the repo/account, then back out without finishing
   app creation. This registers the connection that `aws_amplify_app`
   reuses — Terraform can't drive this OAuth handshake. Skip if already
   connected from a prior project.

   Note: `aws/modules/amplify/main.tf`'s `aws_amplify_app` resource
   intentionally omits `access_token`/`oauth_token`, assuming a
   Terraform-created app can reuse an existing Console-authorized GitHub
   App connection. This hasn't been independently confirmed against AWS's
   API behavior — if `terraform apply` fails while setting up the
   repository/webhook, the fallback is to pass a personal access token via
   `access_token` on `aws_amplify_app` instead.
7. **Provision hosting**: open a PR that touches
   `infrastructure/aws/live/**` and merge it. `terraform-aws.yml` runs and
   applies — this creates the real Amplify app.
8. **Wire up the site deploy trigger** (one time):
   ```
   terraform -chdir=infrastructure/aws/live/prod output -raw webhook_url
   gh secret set AMPLIFY_WEBHOOK_URL --body "<value from above>"
   ```
9. **Verify**: merge a PR touching `site/` and confirm `deploy-site.yml`
   (confirmation) and `deploy-aws.yml` (the actual build) both run, and the
   site goes live at `terraform -chdir=infrastructure/aws/live/prod output
   -raw site_url`. Merge a PR touching only `infrastructure/aws/**` and
   confirm only `terraform-aws.yml` runs — neither site-deploy workflow
   does.

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
6. **Verify**: push a change under `site/` to `main` and confirm the
   `Deploy (Azure)` workflow runs and the Static Web App builds/deploys.
   Push a change touching only `infrastructure/**` and confirm the
   workflow does not run.

## Switching clouds later

Apply the other stack following its steps above, set its deploy secret,
and — once you've confirmed it's serving traffic correctly — optionally
`terraform destroy` the one you're leaving (from its `live/prod` directory)
and remove its now-unused GitHub secret.
