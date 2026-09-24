# CLAUDE.md

Guidance for Claude Code when working in this repository.

# A&E RV Solutions — Claude Code Context

## Project overview
Business website for A&E RV Solutions, a company providing RV solar,
DC-to-AC inversion, and mechanical troubleshooting services.
Domain: aervsolutions.com (registered with GoDaddy, DNS pointing to AWS Amplify).

## Technical stack
- Frontend: Astro 5, static output mode (output: 'static' in astro.config.mjs)
- Styling: hand-written CSS with the token system in src/styles/global.css
  (no CSS framework)
- Interactive islands: React (contact form, chat widget, PDF library viewer)
- Components: shadcn/ui where applicable
- Package manager: npm

## AWS backend (Terraform-provisioned, not Amplify Gen 2)
- Hosting: AWS Amplify Hosting via GitHub → main branch
- Contact form: API Gateway → Lambda → SES
- Schematic library: S3 bucket + CloudFront signed URLs
- Chat backend: API Gateway (REST) → Step Functions (Express) → Bedrock.
  Knowledge base: Bedrock Knowledge Base on S3 Vectors with Titan Text
  Embeddings V2 (`modules/chatbot/kb.tf`). Terraform owns the containers;
  the content lives in the top-level `knowledge-base/` folder (the owner
  chose to keep it in this public repo; it is publicly readable). Merging a
  change there runs the "Chatbot knowledge base sync" workflow, which
  mirrors the folder into the private `ae-rv-chatbot-kb-docs-*` bucket
  (`--delete`) and re-indexes it. Templates live outside that folder
  (`modules/chatbot/kb-templates/`) so they're never indexed
- Employee sign-in: Cognito user pool (Essentials, passwords + passkeys,
  admin-created accounts only) → HTTP API with a JWT authorizer → Lambda
  (`modules/employees/`). Protected content comes only from that API, never
  from the site build. Employee emails never go in the repo; they're added
  with the runbook in infrastructure/README.md → Employees
- Telegram: Lambda webhook pushes chat notifications to owner's cell
- Vector store: S3 Vectors (NOT OpenSearch Serverless)
- Inference model: Claude Haiku 4.5 on Bedrock

## Infrastructure as code
- Tool: Terraform
- Location: `infrastructure/aws/` (bootstrap/, modules/, live/prod/)
- Module structure: amplify/, chatbot/, and employees/ today; contact/,
  library/, telegram/ as those features get built
- Tags: every taggable resource gets `Customer = "AERVSolutions"`, passed
  to each module as `tags` from live/prod (bootstrap sets it with provider
  `default_tags`)
- State backend: S3 with native lockfile (`use_lockfile = true`, Terraform
  >= 1.10). The DynamoDB lock table still exists from bootstrap but is no
  longer used.
- Region: us-west-2

## Safety requirement
Any chat response touching live electrical, battery gas/swelling, or
combined shore/generator/inverter scenarios must route to the safety
gate state in Step Functions and return a technician referral.

Implemented in `infrastructure/aws/modules/chatbot/`: the `Classify` state
(the prompt is in `prompts/classifier.md`) routes to the `Reply_safety_referral`
Pass state, which returns fixed text the model never writes. Any classifier
error or unexpected route also fails closed to it. Changes to the prompts or
routes need the safety eval rerun (see infrastructure/README.md → Chatbot).

## CCA-F learning
Flag when a task maps to a CCA-F exam domain:
prompt engineering, Claude API, RAG architecture,
guardrails/safety, agent architecture, system prompts.

## Code conventions
- Astro components: PascalCase .astro files
- React islands: PascalCase .jsx files with client: directive at usage site.
  The first is `ChatWidget.jsx` (in `BaseLayout.astro`, `client:idle`). An
  island's styles go in a sibling `.css` file it imports, with every class
  prefixed by the component name (e.g. `.chat-widget__`), because that CSS is
  global, not scoped
- API calls: centralized in src/lib/api.js
- Environment variables: `PUBLIC_` prefix for values browser code reads
  (Astro's default; it doesn't expose `VITE_`), no prefix for server-side.
  The site's build-time values are set on the Amplify app from Terraform
  (`live/prod/main.tf`)
- No inline style attributes — use a scoped <style> block in the component

See [README.md](README.md) for additional stack details, directory structure, and dev
commands.

## Commands

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # outputs to dist/
npm run preview   # serve the production build locally
npm run check     # astro check: type/diagnostic check, run by Site CI on PRs
```

There is no test suite or linter configured yet; `npm run check` plus a
successful build is the only automated gate.

## Conventions

- Static-first: only reach for a React island when a piece of UI genuinely
  needs client-side interactivity (e.g. chat widget, contact form). Content
  sections stay plain `.astro` components.
- Styling is hand-written CSS using the token system in
  `src/styles/global.css` — no CSS framework. Reuse existing tokens before
  adding new ones.
- No placeholder/stock imagery gets committed. If a real asset isn't
  available yet, use a CSS placeholder (as `Hero.astro` currently does) and
  leave a note for swapping it in, rather than committing a stand-in image.

## Deployment

Provisioned and live in `us-west-2`. Both the infrastructure and the site
deploy through GitHub Actions, never through a cloud-native push trigger:

- `terraform-aws-plan.yml` runs `fmt -check`, `validate` and `plan` for
  `live/prod` on every PR that touches `infrastructure/aws/**`, and posts the
  plan as a single PR comment that's updated on each push. It uses the
  read-only `github-actions-terraform-plan` role and a placeholder
  `github_access_token` (never the real PAT).
- `terraform-aws.yml` runs `terraform apply`, gated to merged PRs touching
  `infrastructure/aws/live/**` or `infrastructure/aws/modules/**`, and
  authenticates via OIDC (no stored AWS keys).
- The Route 53 zone, Amplify app, branch, domain association and state
  bucket have `prevent_destroy`, so any change that would destroy or replace
  them fails at plan time on the PR. To tear one down on purpose, remove its
  `prevent_destroy` in its own PR first.
- **Chatbot on/off:** the Actions tab → "Chatbot on/off" workflow
  (`chatbot-toggle.yml`). It flips the SSM parameter `/ae-rv/chatbot/enabled`,
  which the chat API checks on every request, and takes effect in seconds
  with no deploy. Fallback: `aws ssm put-parameter --name
  /ae-rv/chatbot/enabled --value true|false --overwrite`. Terraform ignores
  the parameter's value, so applies never undo a toggle.
- The repo is public, so CI logs are world-readable. Both Terraform
  workflows mask the Amplify webhook URL (its token can start builds, and
  the provider doesn't mark it sensitive).
- `deploy-site.yml` is gated to pushes touching `site/**`. It reads
  `infrastructure/deploy-targets.yml` and POSTs an Amplify webhook.

Amplify's own build trigger is deliberately disabled
(`enable_auto_build = false`), because its monorepo path filtering has open
bug reports of building on every commit regardless of path. There are no
pull request preview deployments.

Both workflow triggers are path **allow-lists**, so a change outside those
paths deploys nothing.

`main` is protected by a repo ruleset ("main protection"): every change goes
through a PR (no direct pushes, no force-push), and the `changes` and
`site-build` jobs from `site-ci.yml` plus the `tf-changes` and
`terraform-plan` jobs from `terraform-aws-plan.yml` must pass before merging. The repo admin
role has a PR-only bypass: a red PR can be force-merged (`gh pr merge --admin`
or the web "bypass rules" checkbox), but direct pushes stay blocked even for
admins. Never use `--admin` unless the user explicitly asks for an override.

**Terraform changes and site changes never share a PR.** Anything under
`infrastructure/` goes in its own PR, separate from `site/` changes, even a
one-line change a site feature needs. When a feature needs both, the
infrastructure PR merges (and its apply is verified) first, then the site
PR. Each deploys through its own workflow, so this keeps review, rollback
and the approval gates independent.

**Claude never merges or approves a pull request on its own.** Every merge
needs the user's explicit OK for that specific PR, even when all checks are
green. Merging deploys to production, since the Terraform apply and the site
deploy both run on merge. Open the PR, report the checks and the plan, then
stop and ask. This also covers approving environment deployments (e.g.
`aws-infra`) and closing PRs that aren't Claude's own throwaway test PRs.
Both PR workflows run on every PR and skip their real work when their paths
are untouched, because a path-filtered required check would never start and
would block the PR.
