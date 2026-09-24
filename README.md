# A&E RV Solutions

Website for A&E RV Solutions (RV solar, DC-to-AC inversion, and mechanical
troubleshooting), live at [aervsolutions.com](https://aervsolutions.com).

## Repository layout

| Path | What it is | Details |
|---|---|---|
| [`site/`](site) | The website: Astro (static output), React islands for interactive pieces | [site/README.md](site/README.md) |
| [`infrastructure/aws/`](infrastructure/aws) | Terraform for AWS: Amplify Hosting, Route 53, CI roles | [infrastructure/README.md](infrastructure/README.md) |
| `infrastructure/azure/` | Placeholder for future work, not in use | |
| [`knowledge-base/`](knowledge-base) | What the website chatbot knows (FAQs, capabilities, notes, diagram descriptions). Merging a change here publishes it | [knowledge-base/README.md](knowledge-base/README.md) |
| [`.github/workflows/`](.github/workflows) | PR checks and deploys | [infrastructure/README.md](infrastructure/README.md#where-each-piece-of-automation-runs) |

## How changes reach production

Everything goes through a pull request. Required checks run on the PR.
When it merges, GitHub Actions deploys whatever changed:

- `site/**` → `deploy-site.yml` triggers an Amplify build.
- `infrastructure/aws/live/**` or `modules/**` → `terraform-aws.yml` runs
  `terraform apply`.

## Guardrails

Production is protected before the merge, not after:

- **`main` is protected by a ruleset.** It accepts no direct pushes or
  force-pushes, and every PR must pass the required checks. The repo admin
  can override a red PR (`gh pr merge --admin`), but only through a PR, so
  every override is on record.
- **Site CI** type-checks and builds the site on every PR that touches it.
- **Terraform plan gate:** every infrastructure PR gets a `terraform plan`,
  posted as a PR comment. A failing plan blocks the merge.
- **`prevent_destroy`** on the DNS zone, Amplify app and branch, custom
  domain, and state bucket. Any change that would destroy or replace them
  fails at plan time.
- **Chatbot safety gate and kill switch.** Questions about live electrical
  work, batteries, or shore/generator/inverter setups get a fixed technician
  referral, never a model-written procedure. An on/off switch (Actions →
  "Chatbot on/off") stops the chatbot in seconds, and a daily quota caps
  its volume and cost.
- **Employee sign-in.** The `/employees/` area is served by an API that
  checks a Cognito token on every request, so nothing protected ships in
  the public site. Accounts are admin-created only, and employees sign in
  with a passkey or a password plus an authenticator app.
- **Least-privilege CI.** No stored AWS keys (GitHub OIDC). PR plans run
  under a read-only role scoped to this site's resources, and secrets are
  kept out of the public CI logs.

Full details, including how to override and how to tear something down on
purpose: [infrastructure/README.md → Guardrails and safety](infrastructure/README.md#guardrails-and-safety).

## Local development

```bash
cd site
npm install
npm run dev       # http://localhost:4321
npm run check     # the same type check CI runs
npm run build
```
