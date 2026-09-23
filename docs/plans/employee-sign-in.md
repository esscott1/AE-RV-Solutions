# Deferred plan: Employee sign-in (Cognito)

**Status:** deferred on 2026-09-23 in favour of the public chatbot. Nothing
here is built yet. Re-validate the Step 0 checks before starting, because AWS
features and pricing may have changed.

## Goal
- A hamburger menu in the top-right corner of the site with **Home**,
  **Testimonials**, and **Employees**.
- **Testimonials** (`/testimonials/`): an h1 "Customer Testimonials", to be
  built out later.
- **Employees** (`/employees/`): actually protected. Once signed in, the page
  shows an h1 "Employees' Space".

## Why not a static password
A static password (`wick`) was considered and dropped. On a static site in a
public repo, the password lives in the repo and in the JavaScript sent to
every visitor. The "protected" HTML is also served to anyone who asks.
Getting past it takes view-source or changing one value in the browser's
storage. Real protection needs a check on a server.

## Core rule
Protected content is **never** in the site build. `/employees/` is a public
shell. The content comes from an API that only answers requests carrying a
valid Cognito token (an API Gateway **JWT authorizer**).

```
Browser ─► /employees/ (public shell)
  └ "Sign in" ─► ae-rv-employees.auth.us-west-2.amazoncognito.com (managed login: passkey or email code)
       └ back with tokens (auth code + PKCE)
  └ GET <api>/employee-content  Authorization: Bearer <token>
       API Gateway HTTP API ─ JWT authorizer ─► Lambda ─► JSON content
```

## Decisions
- **Scale:** 3–4 employees, at most about 12 sign-in emails a day, very low
  traffic.
- **Sign-in:** passwordless, by **passkey or a one-time code sent by email**.
  Employees sign in with their existing personal address (Gmail, Yahoo,
  etc.). Only people an admin adds can sign in; there's no public sign-up.
- **Login domain:** Cognito's own prefix domain, not a custom domain, which
  keeps PR 1 small. Passkeys are tied to the login domain, so switching to a
  custom domain later means each employee re-registers theirs (about 2
  minutes each).
- **No federated login** ("Sign in with Google" etc.). If it's added later,
  it needs its own allow-list, because Cognito creates a federated account
  for anyone on their first sign-in.
- **MFA off.** Cognito doesn't allow passwordless sign-in when MFA is
  required, and a passkey with required user verification (fingerprint,
  face, or PIN) already combines two factors.
- **SES:** if email codes require SES, keep SES in sandbox mode and verify
  each employee's address once. There's no production-access request.
- **Order:** the Cognito infrastructure ships to production first. The site
  nav and pages follow in their own PR.

## PR 1: Cognito infrastructure (Terraform only)

### Step 0: Verify before building
1. Whether `EMAIL_OTP` sign-in needs SES. If it does: add an SES domain
   identity for aervsolutions.com with DKIM records in Route 53, send from
   `no-reply@aervsolutions.com`, and keep SES in sandbox mode.
2. Whether `PASSWORD` must be listed in `allowed_first_auth_factors`, and how
   to create users with no password.
3. The passkey `relying_party_id` for a Cognito prefix domain.
4. Essentials tier pricing at about 4 monthly active users. **If it isn't
   free, stop and decide.** The fallback is the free Lite tier with email +
   password and an optional authenticator app.
5. Whether the domain prefix `ae-rv-employees` is available.

### Step 1: CI role permissions (`bootstrap/`, applied locally)
- **Apply role:**
  - `cognito-idp`
  - `apigateway` on `/apis*`
  - `lambda` on `ae-rv-employees-*`
  - `iam` role management and `PassRole` scoped to `ae-rv-employees-*`
  - `logs`
  - `ses` if needed
- **Plan role:** the matching read-only actions.
- When a CI plan reports AccessDenied, add the exact action it names.

### Step 2: New module `infrastructure/aws/modules/employees/`
- **User pool:**
  - `user_pool_tier = "ESSENTIALS"`, email as the username, email
    auto-verified
  - `allow_admin_create_user_only = true`
  - `sign_in_policy { allowed_first_auth_factors = ["WEB_AUTHN", "EMAIL_OTP"] }`
    (plus `PASSWORD` only if Step 0 says it's mandatory)
  - `web_authn_configuration { user_verification = "required" }`
  - MFA off
  - `deletion_protection = "ACTIVE"` plus `prevent_destroy`
- **Login domain:** prefix `ae-rv-employees`, managed login version 2,
  default branding.
- **App client:**
  - public, with no client secret
  - authorization-code flow with PKCE, scopes `openid email profile`
  - callbacks and logouts for `https://aervsolutions.com/employees/`,
    `https://www.aervsolutions.com/employees/`, and
    `http://localhost:4321/employees/`
  - `ALLOW_USER_AUTH` + refresh
  - `prevent_user_existence_errors`
- **API:**
  - HTTP API with a JWT authorizer (the pool's issuer, audience = client
    ID), `GET /employee-content`
  - CORS for the prod, www, and localhost origins, plus throttling
- **Lambda** `ae-rv-employees-content`: Python, returning
  `{"title": "Employees' Space", "email": <from claims>}`, with a log-only
  role and 30-day log retention.
- **SES identity plus DKIM records**, if Step 0 requires them.
- **Outputs:** the pool ID, client ID, login domain, API URL, and issuer.
  These are public identifiers, not secrets.

### Step 3: `live/prod` + docs
- Call the module, and feed `PUBLIC_COGNITO_*` and `PUBLIC_EMPLOYEE_API_URL`
  into the Amplify module's `environment_variables`.
- Add a runbook for **adding and removing employees**
  (`aws cognito-idp admin-create-user` / `admin-delete-user`, plus SES
  recipient verification if in sandbox) and first-time sign-in (email code,
  then register a passkey).

### Verification (no UI yet)
- Get tokens with a command-line email-code sign-in (`initiate-auth` with
  `USER_AUTH`).
- The API returns **401 without a token** and **200 with one**.

## PR 2: Site nav + pages with real sign-in
- **`SiteNav.astro`:** a hamburger menu fixed to the top-right corner.
  - A static `.astro` component with a small script, not a React island.
  - `aria-expanded`; Esc and outside-click close it; `aria-current` on the
    current page; existing CSS tokens; a 44px tap target.
  - `BaseLayout` renders it, along with the Footer (moved out of
    `index.astro`).
- **`pages/testimonials.astro`:** h1 "Customer Testimonials".
- **`pages/employees.astro`:** a `noindex` public shell, plus the React
  island `EmployeeSignIn.jsx`:
  - It uses `oidc-client-ts` for the PKCE redirect, with tokens in
    sessionStorage.
  - `src/lib/api.js` `getEmployeeContent()` fetches the protected API.
  - It renders "Employees' Space" **from the API response**, so even the
    heading isn't in the public build.
  - Sign-out uses Cognito's logout endpoint.
- **Local dev:** `site/.env` gets its values from `terraform output`. The
  login page already allows localhost as a callback.

## Out of scope
- A custom login domain
- Federated sign-in
- Custom login branding
- Real employee content
