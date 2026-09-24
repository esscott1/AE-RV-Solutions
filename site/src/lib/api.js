// All calls from the site to backend APIs live here (CLAUDE.md convention).
//
// Chat API: infrastructure/aws/modules/chatbot. Both values are set at build
// time: on the Amplify app by Terraform in production, and from site/.env
// locally (see site/.env.example). The key isn't a secret: it only ties
// requests to the API's usage plan (daily quota + throttle).
const CHAT_API_URL = import.meta.env.PUBLIC_CHAT_API_URL;
const CHAT_API_KEY = import.meta.env.PUBLIC_CHAT_API_KEY;

export const chatConfigured = Boolean(CHAT_API_URL && CHAT_API_KEY);

const SOURCES = new Set(['knowledge_base', 'both', 'general']);

const UNAVAILABLE = {
  route: 'unavailable',
  reply:
    "Sorry, I can't answer right now. Please try again later or contact us directly.",
};

// Whether the chatbot is switched on. Any failure counts as off, the same
// fail-closed rule the server uses.
export async function getChatStatus() {
  if (!chatConfigured) return false;
  try {
    const res = await fetch(`${CHAT_API_URL}/chat/status`);
    if (!res.ok) return false;
    const body = await res.json();
    return body.enabled === true;
  } catch {
    return false;
  }
}

// Sends the conversation and returns {route, reply, source}. It never
// throws. `source` comes only with answers: "knowledge_base", "both", or
// "general" (see modules/chatbot); otherwise it's undefined. The API answers
// errors (400 invalid, 429 busy, 502 unavailable) in the same {route, reply}
// shape, so those are passed through. Anything else becomes a generic
// "unavailable" reply.
export async function sendChatMessage(messages) {
  if (!chatConfigured) return UNAVAILABLE;
  try {
    const res = await fetch(`${CHAT_API_URL}/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': CHAT_API_KEY },
      body: JSON.stringify({ messages }),
    });
    const body = await res.json().catch(() => null);
    if (body && typeof body.route === 'string' && typeof body.reply === 'string') {
      const source = SOURCES.has(body.source) ? body.source : undefined;
      return { route: body.route, reply: body.reply, source };
    }
    return UNAVAILABLE;
  } catch {
    return UNAVAILABLE;
  }
}

// Employee API: infrastructure/aws/modules/employees. Every route requires
// the signed-in employee's Cognito ID token; API Gateway rejects anything
// else with a 401 before any code runs.
const EMPLOYEE_API_URL = import.meta.env.PUBLIC_EMPLOYEE_API_URL;

// Who's signed in, plus the Employees' Space content. Returns
// {status: 'ok', me}, {status: 'unauthorized'} (the token was refused: sign
// in again), or {status: 'error'}. Fails closed: nothing is shown unless the
// API answered 200 with the expected shape.
export async function getEmployeeMe(idToken) {
  if (!EMPLOYEE_API_URL || !idToken) return { status: 'unauthorized' };
  try {
    const res = await fetch(new URL('me', EMPLOYEE_API_URL), {
      headers: { Authorization: `Bearer ${idToken}` },
    });
    if (res.status === 401 || res.status === 403) return { status: 'unauthorized' };
    if (!res.ok) return { status: 'error' };
    const me = await res.json();
    if (typeof me?.email !== 'string' || typeof me?.title !== 'string') return { status: 'error' };
    return {
      status: 'ok',
      me: {
        email: me.email,
        title: me.title,
        body: typeof me.body === 'string' ? me.body : '',
        isAdmin: me.isAdmin === true,
      },
    };
  } catch {
    return { status: 'error' };
  }
}

// Cognito's self-service API, called with the employee's access token. It
// only ever acts on that employee's own account. The endpoint is the
// regional host of the user pool's issuer.
function cognitoEndpoint() {
  const authority = import.meta.env.PUBLIC_COGNITO_AUTHORITY;
  return `${new URL(authority).origin}/`;
}

async function cognito(operation, body) {
  const res = await fetch(cognitoEndpoint(), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': `AWSCognitoIdentityProviderService.${operation}`,
    },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const error = new Error(data.message || `Cognito ${operation} failed (${res.status})`);
    error.code = (data.__type || '').split('#').pop();
    throw error;
  }
  return data;
}

// {authenticator: bool, passkeys: [{id, name, createdAt}]} for the
// signed-in employee. The name is what the passkey provider reported (e.g.
// the password manager that holds it).
export async function getAccountSecurity(accessToken) {
  const [user, passkeys] = await Promise.all([
    cognito('GetUser', { AccessToken: accessToken }),
    cognito('ListWebAuthnCredentials', { AccessToken: accessToken, MaxResults: 20 }),
  ]);
  return {
    authenticator: (user.UserMFASettingList ?? []).includes('SOFTWARE_TOKEN_MFA'),
    passkeys: (passkeys.Credentials ?? []).map((credential) => ({
      id: credential.CredentialId,
      name: credential.FriendlyCredentialName || 'Passkey',
      // CreatedAt is epoch seconds.
      createdAt: credential.CreatedAt ? new Date(credential.CreatedAt * 1000) : null,
    })),
  };
}

// Removes one of the signed-in employee's own passkeys.
export async function removePasskey(accessToken, credentialId) {
  await cognito('DeleteWebAuthnCredential', { AccessToken: accessToken, CredentialId: credentialId });
}

// Step 1 of authenticator setup: returns the secret the app needs.
export async function startAuthenticatorSetup(accessToken) {
  const { SecretCode } = await cognito('AssociateSoftwareToken', { AccessToken: accessToken });
  return SecretCode;
}

// Step 2: checks a 6-digit code from the app, then turns the authenticator
// on as this employee's MFA method. Password sign-ins ask for a code from
// then on.
export async function finishAuthenticatorSetup(accessToken, code) {
  const { Status } = await cognito('VerifySoftwareToken', {
    AccessToken: accessToken,
    UserCode: code,
    FriendlyDeviceName: 'Authenticator app',
  });
  if (Status !== 'SUCCESS') throw new Error('That code did not match. Try the newest code.');
  await cognito('SetUserMFAPreference', {
    AccessToken: accessToken,
    SoftwareTokenMfaSettings: { Enabled: true, PreferredMfa: true },
  });
}
