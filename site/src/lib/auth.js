// Employee sign-in session: Cognito managed login with the authorization code
// flow + PKCE, via oidc-client-ts. Tokens live in sessionStorage (the
// library's default), so they're gone when the tab closes.
//
// The values are public identifiers set at build time: on the Amplify app by
// Terraform in production, and from site/.env locally (see site/.env.example).
// Nothing here is protected by being hidden: the employee API checks every
// token (infrastructure/aws/modules/employees).
import { UserManager } from 'oidc-client-ts';

const AUTHORITY = import.meta.env.PUBLIC_COGNITO_AUTHORITY;
const DOMAIN = import.meta.env.PUBLIC_COGNITO_DOMAIN;
const CLIENT_ID = import.meta.env.PUBLIC_COGNITO_CLIENT_ID;

export const signInConfigured = Boolean(
  AUTHORITY && DOMAIN && CLIENT_ID && import.meta.env.PUBLIC_EMPLOYEE_API_URL,
);

// Sign-in, sign-out, and passkey pages all return here. Each origin's
// /employees/ is registered on the Cognito app client.
const pageUrl = () => `${window.location.origin}/employees/`;

// SiteNav and AccountMenu listen for this to update for sign-in. They
// read the session themselves, so public pages don't load this module.
export const AUTH_CHANGE_EVENT = 'ae-rv-auth-change';
function announceAuthChange() {
  window.dispatchEvent(new Event(AUTH_CHANGE_EVENT));
}

let manager;
function userManager() {
  manager ??= new UserManager({
    authority: AUTHORITY,
    client_id: CLIENT_ID,
    redirect_uri: pageUrl(),
    response_type: 'code',
    // aws.cognito.signin.user.admin lets the access token manage the
    // employee's own account (authenticator app, passkey list), nothing else.
    scope: 'openid email profile aws.cognito.signin.user.admin',
    loadUserInfo: false,
    automaticSilentRenew: false,
  });
  return manager;
}

// Finishes a sign-in when Cognito has just redirected back with ?code=…,
// then removes the code from the address bar. Returns the user, or null if
// this isn't a sign-in redirect. Throws if the sign-in failed.
export async function completeSignIn() {
  const params = new URLSearchParams(window.location.search);
  if (!params.has('state') || !(params.has('code') || params.has('error'))) return null;
  try {
    const user = await userManager().signinRedirectCallback();
    announceAuthChange();
    return user;
  } finally {
    window.history.replaceState(null, '', pageUrl());
  }
}

// The signed-in user with unexpired tokens, or null. Expired tokens are
// renewed with the refresh token (valid 12 hours) when possible.
export async function currentUser() {
  const user = await userManager().getUser();
  if (!user) return null;
  if (!user.expired) return user;
  try {
    return await userManager().signinSilent();
  } catch {
    await userManager().removeUser();
    return null;
  }
}

export function signIn() {
  return userManager().signinRedirect();
}

// Cognito's managed page for registering a passkey. It uses the sign-in
// session Cognito keeps on its own domain, and returns to /employees/.
export function addPasskeyUrl() {
  const query = new URLSearchParams({ client_id: CLIENT_ID, redirect_uri: pageUrl() });
  return `https://${DOMAIN}/passkeys/add?${query}`;
}
