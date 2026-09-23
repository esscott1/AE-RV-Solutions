# Chatbot knowledge base

Everything in this folder (except README files) is what the website
chatbot knows. **Merging a PR that changes this folder publishes it**: the
"Chatbot knowledge base sync" workflow mirrors it to the knowledge base's
S3 bucket and re-indexes it, and the chatbot uses the new content within a
few minutes.

> **This repository is public.** Anything here can be read, and copied, by
> anyone on GitHub. Only add what you're comfortable publishing. Never add
> customer details, private pricing, or anything confidential.

## Folders

| Folder | What goes in it | Template |
|---|---|---|
| `capabilities/` | One "how do I…" capability per file, **with exactly one "Also possible with this setup" pairing**. The chatbot offers that pairing as its extra suggestion | [capability](../infrastructure/aws/modules/chatbot/kb-templates/capability-template.md) |
| `faq/` | Questions and answers, many per file, grouped by topic | [faq](../infrastructure/aws/modules/chatbot/kb-templates/faq-template.md) |
| `diagrams/` | Each diagram **plus a `.md` description with the same name** (the chatbot reads only the description) | [diagram](../infrastructure/aws/modules/chatbot/kb-templates/diagram-template.md) |
| `notes/` | Free-form notes with `#`/`##` headings | none |

File names: lowercase with hyphens, e.g. `capabilities/run-a-microwave-off-grid.md`.
Writing tips are in the [templates README](../infrastructure/aws/modules/chatbot/kb-templates/README.md).

## How changes go live

1. Edit or add files on a branch and open a PR. (Neither the site build nor
   the Terraform plan runs for this folder, so the checks pass quickly.)
2. The owner reviews and merges.
3. The sync workflow runs automatically. Its summary shows how many
   documents were indexed, updated, removed, or failed.

Keep changes to this folder in their own PRs, separate from Terraform
changes. Both deploy on merge, and a sync that races an unfinished apply
can fail. If a sync ever fails that way, run it again from Actions →
"Chatbot knowledge base sync" → Run workflow.

The repo is the **single source of truth**. The sync mirrors this folder
exactly, deletions included, so files uploaded straight to the S3 bucket
are removed on the next sync.
