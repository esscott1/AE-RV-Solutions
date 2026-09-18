# Infrastructure (Terraform)

IaC for A&E RV Solutions. Step 1: AWS Amplify Hosting for the Astro site in
[`site/`](../site). Later steps (not yet built): a knowledge library
(`modules/library`) and an AI chatbot backend (`modules/chatbot`,
`modules/telegram`).

## Layout

- `bootstrap/` — one-time, local-state config that creates the S3
  bucket + DynamoDB table used as the remote state backend for everything
  else. Run once per AWS account.
- `modules/amplify/` — reusable module: one Amplify Hosting app, branch,
  and deploy webhook.
- `live/prod/` — the only environment right now. Calls `modules/amplify`,
  using the S3/DynamoDB backend from `bootstrap`.

## Why deploys go through a webhook instead of Amplify's native auto-build

The site lives in `site/`, and infrastructure changes live in
`infrastructure/`, in the same repo. Amplify's own push trigger has no
reliable way to ignore one directory while watching another — its
documented "monorepo app root" build-trigger filtering has multiple open
bug reports of triggering builds on every commit regardless of path (see
`infrastructure/modules/amplify/main.tf` for links). So:

- `aws_amplify_branch.enable_auto_build` is `false` — Amplify never builds
  on its own from a GitHub push.
- `.github/workflows/deploy.yml` triggers on push to `main` with
  `paths-ignore: ["infrastructure/**"]`, and its only job POSTs to an
  Amplify webhook to start a build. A push touching only
  `infrastructure/**` never runs the workflow, so it never triggers a
  build.

## Running it

1. **AWS credentials**: configure the AWS CLI for the target account,
   region `us-west-2`. Terraform ≥ 1.9.
2. **One-time: authorize the Amplify GitHub App.** In the AWS Amplify
   console, start "New app → Host web app → GitHub" and authorize the AWS
   Amplify GitHub App for the repo/account, then back out without finishing
   app creation. This registers the connection that `aws_amplify_app`
   reuses — Terraform can't drive this OAuth handshake. Skip if already
   connected from a prior project.

   Note: this repo's `aws_amplify_app` resource intentionally omits
   `access_token`/`oauth_token`, assuming a Terraform-created app can reuse
   an existing Console-authorized GitHub App connection. This hasn't been
   independently confirmed against AWS's API behavior — if `terraform
   apply` fails while setting up the repository/webhook, the fallback is
   to pass a personal access token via `access_token` on `aws_amplify_app`
   instead.
3. **Bootstrap the state backend** (local state, run once):
   ```
   cd infrastructure/bootstrap
   terraform init
   terraform apply
   ```
4. Fill in `infrastructure/live/prod/backend.hcl` with the `state_bucket_name`
   and `lock_table_name` outputs from step 3.
5. **Provision hosting**:
   ```
   cd infrastructure/live/prod
   terraform init -backend-config=backend.hcl
   terraform plan
   terraform apply
   ```
6. **Wire up the deploy trigger** (one time):
   ```
   terraform output -raw webhook_url
   gh secret set AMPLIFY_WEBHOOK_URL --body "<value from above>"
   ```
7. **Verify**: push a change under `site/` to `main` and confirm the
   `Deploy` workflow runs and Amplify builds. Push a change touching only
   `infrastructure/**` and confirm the workflow does not run.
