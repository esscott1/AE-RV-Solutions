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

## Deploying to AWS

1. **AWS credentials**: configure the AWS CLI with an `OTS-Prod-Deploy`
   named profile for the target account, region `us-west-2`
   (`aws configure --profile OTS-Prod-Deploy`). Terraform ≥ 1.9. Both
   `bootstrap` and `live/prod` default their `profile` variable to
   `OTS-Prod-Deploy` — override with `-var profile=<name>` if you use a
   different local profile name.
2. **One-time: authorize the Amplify GitHub App.** In the AWS Amplify
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
3. **Bootstrap the state backend** (local state, run once):
   ```
   cd infrastructure/aws/bootstrap
   terraform init
   terraform apply
   ```
4. Fill in `infrastructure/aws/live/prod/backend.hcl` with the
   `state_bucket_name` and `lock_table_name` outputs from step 3.
5. **Provision hosting**:
   ```
   cd infrastructure/aws/live/prod
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
   `Deploy (AWS)` workflow runs and Amplify builds. Push a change touching
   only `infrastructure/**` and confirm the workflow does not run.

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
