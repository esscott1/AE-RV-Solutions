# Point aervsolutions.com at the Amplify site

> Working plan, AI-generated at Eric Scott's direction. Lives in
> `AI_Plans/` at the repo root deliberately: both GitHub Actions workflows
> use path allow-lists (`infrastructure/aws/live|modules/**` for
> `terraform-aws.yml`, `site/**` for `deploy-site.yml`), so changes here
> trigger neither a Terraform run nor a site deployment.

**Status as of 2026-09-22: steps 1 and 2 are complete.** The Route 53
hosted zone exists and the GoDaddy nameserver change has fully propagated —
verified at the `.com` registry itself (`a.gtld-servers.net`), not just a
public resolver. Next action is **step 3**.

Delegation confirmed live:

```
ns-408.awsdns-51.com
ns-724.awsdns-26.net
ns-1294.awsdns-33.org
ns-1873.awsdns-42.co.uk
```

## Context

The site is live and verified at `https://main.du8gjlas8igsf.amplifyapp.com`,
but that URL is not something a customer can be handed. Eric has purchased
`aervsolutions.com` at GoDaddy and wants it to resolve to the deployed site.

Verified starting state (read-only checks against AWS and public DNS):

- Amplify app `ae-rv-solutions-prod`, app ID **`du8gjlas8igsf`**, region
  `us-west-2`, single branch `main` (PRODUCTION, `enable_auto_build = false`).
- **Zero domain associations** on the app.
- **Zero Route 53 hosted zones** in account `998976076628` (before step 1).
- `aervsolutions.com` was on GoDaddy default nameservers
  (`ns21`/`ns22.domaincontrol.com`), apex pointing at GoDaddy parking,
  `www` CNAME'd to apex.
- **No MX and no TXT records** — nothing to preserve, so the nameserver
  change could not break email or domain verification.

Two decisions confirmed with Eric:

1. **DNS moves to Route 53** (GoDaddy stays the registrar).
2. **Console first, Terraform after** — get it resolving today, then import
   into state so the repo stays the source of truth.

### Why Route 53 rather than staying on GoDaddy DNS

This is the load-bearing technical reason, confirmed in AWS's own docs:
Amplify requires an **ANAME/ALIAS record at the apex**, and AWS states
plainly that **"GoDaddy doesn't support ANAME/ALIAS records."** GoDaddy's
CNAME form additionally forbids `@` in the Name field, so a CNAME at the
root is blocked outright. Staying on GoDaddy DNS would mean the apex is a
302 *redirect* (GoDaddy Forwarding) rather than a real origin. Route 53's
A-record ALIAS handles the apex natively, and with the hosted zone in the
same account Amplify writes all the records itself.

**Trap to avoid:** GoDaddy Forwarding automatically switches a domain back
to GoDaddy nameservers. Never enable Forwarding on this domain — it would
silently undo the delegation done in step 2.

---

## Phase 1 — Get it resolving (console + GoDaddy, manual)

Order matters: create the zone and delegate **before** adding the domain in
Amplify, so DNS is already authoritative when ACM starts validating.

### 1. Create the Route 53 hosted zone — DONE

AWS Console → **Route 53** → **Hosted zones** → **Create hosted zone**.

- Domain name: `aervsolutions.com`
- Type: **Public hosted zone**
- Create.

Record the four `ns-*.awsdns-*` nameservers from the **NS** record, and the
**Hosted zone ID** (`Z...`) — the zone ID is needed again in step 7.

### 2. Repoint nameservers at GoDaddy — DONE

GoDaddy → **My Products** → `aervsolutions.com` → **DNS** → **Nameservers**
→ **Change Nameservers** → **I'll use my own nameservers**.

- Replace `ns21.domaincontrol.com` / `ns22.domaincontrol.com` with all four
  Route 53 nameservers (drop any trailing dot).
- Save. GoDaddy warns that existing DNS records stop applying — that is the
  intent, and nothing of value was in the GoDaddy zone.
- If GoDaddy reports **DNSSEC** is enabled, disable it first. Changing
  nameservers with a stale DS record at the registry causes total
  resolution failure, which looks like a broken domain rather than a
  misconfiguration.

Verify delegation (expect the `awsdns` nameservers, not `domaincontrol`):

```
nslookup -type=NS aervsolutions.com 8.8.8.8
nslookup -type=NS aervsolutions.com a.gtld-servers.net
```

The second command queries the `.com` registry directly, which is the
stronger check — a public resolver can serve a cached answer, the registry
cannot.

Typically minutes, but allow up to 48h. **Wait for this to flip before
step 3** — ACM validation starts immediately on domain add and backs off
its retry cadence over time, so adding the domain against stale
delegation is the main way this gets stuck in `PENDING_VERIFICATION`.

### 3. Add the custom domain in Amplify — NEXT

AWS Console → **Amplify** → `ae-rv-solutions-prod` → **Hosting** →
**Custom domains** → **Add domain**.

- Domain: `aervsolutions.com` — it should **autocomplete from the hosted
  zone list**, which is the visual confirmation Amplify can see the zone.
- Keep the default: Amplify creates both `aervsolutions.com` and
  `www.aervsolutions.com`, with the root redirecting to `www`.
- Certificate: **Amplify managed** (the default). Do not supply a custom
  cert — Amplify provisions an ACM cert valid 13 months and auto-renews it.
- **Configure domain** / **Add domain**.

Because the hosted zone is in the same account, Amplify writes the
validation and routing records itself — there are no records to copy by
hand. Status moves through `PENDING_VERIFICATION` → `AVAILABLE`, usually
well under an hour but documented as up to 24h.

### 4. Verify

```
curl -sI https://aervsolutions.com | head -3
curl -sI https://www.aervsolutions.com | head -3
```

Expect HTTP 200 on `www` (and a redirect from the apex), a valid
certificate, and the live hero markup:

```
curl -s https://www.aervsolutions.com | grep -o 'sizes="80vw"'
```

---

## Phase 2 — Bring it under Terraform (import, no re-creation)

The CI role's IAM is the blocker here, and it must be fixed **first**.

### 5. Expand the CI role's permissions (local apply — required first)

`infrastructure/aws/bootstrap/main.tf` currently grants the
`github-actions-terraform` role exactly four statements: S3 state,
DynamoDB lock, and `amplify:*`. It has **no `route53:*` at all**, so
without this step even a `terraform plan` would fail on refresh.

Two distinct needs:

- Managing `aws_route53_zone`: `CreateHostedZone`, `GetHostedZone`,
  `ListHostedZones`, `ListHostedZonesByName`, `ListTagsForResource`,
  `ChangeTagsForResource`, `UpdateHostedZoneComment`, `DeleteHostedZone`,
  `GetChange`.
- Records written **on Amplify's behalf**: Amplify Hosting has **no
  service-linked role** and uses forward access sessions, so those writes
  are authorized against the *calling* role. Mirroring AWS's own
  `AdministratorAccess-Amplify` policy: `ListHostedZonesByName`,
  `ListResourceRecordSets`, `ChangeResourceRecordSets`.

Route 53 is global — do **not** region-scope these.

**No ACM permissions and no `aws_acm_certificate` resource are needed.**
Amplify provisions and manages the cert; `AdministratorAccess-Amplify`
contains zero `acm:*` actions. Adding an ACM resource would create a
second, unused certificate.

`bootstrap` is deliberately excluded from CI and uses local state, so apply
it by hand:

```
export AWS_PROFILE=OTS-Prod-Deploy
terraform -chdir=infrastructure/aws/bootstrap init
terraform -chdir=infrastructure/aws/bootstrap apply
```

> The Route 53 action list above is **inferred** from the documented
> prefix+operation-name rule and AWS's managed policy, not copied from an
> authoritative "required permissions" table. If the first CI plan hits
> AccessDenied, read the actual denied action out of CloudTrail — the same
> technique that resolved the OIDC trust-policy bug — rather than widening
> to `route53:*`.

### 6. Add the Terraform resources

`infrastructure/aws/modules/amplify/` — new variable `domain_name`
(string, default `""`), and the resource created with `count` so the
module still works when no domain is set:

```hcl
resource "aws_amplify_domain_association" "this" {
  count       = var.domain_name != "" ? 1 : 0
  app_id      = aws_amplify_app.this.id
  domain_name = var.domain_name

  # Apex. An empty prefix is explicitly valid and is the documented way to
  # express the root domain; the argument is Required, so it must be
  # present rather than omitted.
  sub_domain {
    branch_name = aws_amplify_branch.this.branch_name
    prefix      = ""
  }

  sub_domain {
    branch_name = aws_amplify_branch.this.branch_name
    prefix      = "www"
  }

  # The create path already waits unconditionally (5m). This second wait is
  # a hardcoded 15m with no configurable `timeouts` block, so leaving it on
  # risks a red CI run on any future change for reasons unrelated to the
  # change itself.
  wait_for_verification = false
}
```

The hosted zone is created in `live/prod` (it is environment state, not a
property of the hosting module), with `domain_name` defaulted so the CI
apply keeps working — `terraform-aws.yml` wires no `TF_VAR_domain_name`
and there is no `terraform.tfvars`, so a *required* variable here would
break CI.

Add outputs for the zone's nameservers and the domain URL.

### 7. Import both resources into state

Run locally — CI only ever runs `apply`. The local SSO session is
AdministratorAccess, and `backend.hcl` carries no profile by design, so
`AWS_PROFILE` is what authenticates:

```
export AWS_PROFILE=OTS-Prod-Deploy
cd infrastructure/aws/live/prod
terraform init -backend-config=backend.hcl

terraform import 'module.amplify.aws_amplify_domain_association.this[0]' \
  du8gjlas8igsf/aervsolutions.com
terraform import aws_route53_zone.primary <HOSTED_ZONE_ID_FROM_STEP_1>
```

Import IDs verified against the provider source: the domain association
uses `APPID/DOMAINNAME`; the zone takes a bare zone ID with no
`/hostedzone/` prefix.

### 8. Confirm the import is clean

```
terraform plan
```

Target: **no changes**. Two benign diffs are expected and acceptable:

- `aws_route53_zone.comment` — defaults to `Managed by Terraform`, but a
  console-created zone has none. Either set `comment` to match or let one
  apply write it.
- `wait_for_verification` — config-only, not returned by the API, so it may
  show an in-place update. It triggers no API call.

Anything else — particularly a **replace** on the domain association —
means stop. Re-creating it would tear down the live domain and re-issue
the certificate.

### 9. Prove CI still works

Open a PR touching `infrastructure/aws/live/**`, merge, approve the
`aws-infra` gate, and confirm `terraform-aws.yml` applies with **0 added,
0 changed, 0 destroyed**. That is what proves the imported state matches
reality *and* that the expanded IAM role can refresh Route 53.

---

## Also worth fixing

`CLAUDE.md` still says the domain is **`OTSconsulting.info`**. That is now
wrong and should say `aervsolutions.com`. No domain name appears anywhere
under `infrastructure/` today, so `CLAUDE.md` is the only stale reference.

## Out of scope

- `site/src/assets/heroImage2.jpg`, still untracked in the working tree.
- Removing the unused DynamoDB lock table from `bootstrap`.
- Azure (`azure: false`); no custom-domain resource exists on that stack.

## Verification summary

| Step | Check | Expect |
|---|---|---|
| Delegation | `nslookup -type=NS aervsolutions.com a.gtld-servers.net` | four `awsdns` NS |
| Domain live | `curl -sI https://www.aervsolutions.com` | 200, valid cert |
| Content | `curl -s https://www.aervsolutions.com \| grep 'sizes="80vw"'` | match |
| Apex | `curl -sI https://aervsolutions.com` | redirect to `www` |
| Import | `terraform plan` | no changes (bar the two noted) |
| CI | merged infra PR | `0 added, 0 changed, 0 destroyed` |
