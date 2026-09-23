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
- Chat backend: API Gateway → Step Functions → Bedrock Knowledge Base (S3 Vectors)
- Telegram: Lambda webhook pushes chat notifications to owner's cell
- Vector store: S3 Vectors (NOT OpenSearch Serverless)
- Inference model: Claude Haiku 4.5 on Bedrock

## Infrastructure as code
- Tool: Terraform
- Location: `infrastructure/aws/` (bootstrap/, modules/, live/prod/)
- Module structure: amplify/ today; contact/, library/, chatbot/, telegram/
  as those features get built
- State backend: S3 with native lockfile (`use_lockfile = true`, Terraform
  >= 1.10). The DynamoDB lock table still exists from bootstrap but is no
  longer used.
- Region: us-west-2

## Safety requirement
Any chat response touching live electrical, battery gas/swelling, or
combined shore/generator/inverter scenarios must route to the safety
gate state in Step Functions and return a technician referral.

## CCA-F learning
Flag when a task maps to a CCA-F exam domain:
prompt engineering, Claude API, RAG architecture,
guardrails/safety, agent architecture, system prompts.

## Code conventions
- Astro components: PascalCase .astro files
- React islands: PascalCase .jsx files with client: directive at usage site
- API calls: centralized in src/lib/api.js
- Environment variables: VITE_ prefix for client-side, no prefix for server-side
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

- `terraform-aws.yml` runs `terraform apply`, gated to merged PRs touching
  `infrastructure/aws/live/**` or `infrastructure/aws/modules/**`, and
  authenticates via OIDC (no stored AWS keys).
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
`site-build` jobs from `site-ci.yml` must pass before merging. The repo admin
role has a PR-only bypass: a red PR can be force-merged (`gh pr merge --admin`
or the web "bypass rules" checkbox), but direct pushes stay blocked even for
admins. Never use `--admin` unless the user explicitly asks for an override. `site-ci.yml` runs on every PR, not
only site PRs, and skips the build when `site/**` is untouched, because a
path-filtered required check would never start and would block the PR.
