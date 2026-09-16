# CLAUDE.md

Guidance for Claude Code when working in this repository.

# A&E RV Solutions — Claude Code Context

## Project overview
Business website for A&E RV Solutions, a company providing RV solar,
DC-to-AC inversion, and mechanical troubleshooting services.
Domain: OTSconsulting.info (registered with GoDaddy, DNS pointing to AWS Amplify).

## Technical stack
- Frontend: Astro 5, static output mode (output: 'static' in astro.config.mjs)
- Styling: Tailwind CSS v4
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
- Module structure: amplify/, contact/, library/, chatbot/, telegram/
- State backend: S3 + DynamoDB lock table
- Region: us-east-1

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
- No inline styles — Tailwind classes only

See [README.md](README.md) for additional stack details, directory structure, and dev
commands.

## Commands

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # outputs to dist/
npm run preview   # serve the production build locally
```

There is no test suite or linter configured yet.

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

## Deployment (planned)

GitHub repo connected to AWS Amplify Hosting (`us-east-1`). Push to `main`
triggers a build; pull requests get preview deployments. Infrastructure is
planned to live in Terraform under an `infra/` directory, module-per-feature.
Nothing here is provisioned yet — treat deployment/infra instructions as
forward-looking, not current state.
