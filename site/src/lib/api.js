// All calls from the site to backend APIs live here (CLAUDE.md convention).
//
// Chat API: infrastructure/aws/modules/chatbot. Both values are set at build
// time: on the Amplify app by Terraform in production, and from site/.env
// locally (see site/.env.example). The key isn't a secret: it only ties
// requests to the API's usage plan (daily quota + throttle).
const CHAT_API_URL = import.meta.env.PUBLIC_CHAT_API_URL;
const CHAT_API_KEY = import.meta.env.PUBLIC_CHAT_API_KEY;

export const chatConfigured = Boolean(CHAT_API_URL && CHAT_API_KEY);

const UNAVAILABLE = {
  route: 'unavailable',
  reply:
    "Sorry, I can't answer right now. Please try again later or contact A&E RV Solutions directly.",
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

// Sends the conversation and returns {route, reply}. It never throws. The
// API answers errors (400 invalid, 429 busy, 502 unavailable) in the same
// {route, reply} shape, so those are passed through. Anything else becomes
// a generic "unavailable" reply.
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
      return { route: body.route, reply: body.reply };
    }
    return UNAVAILABLE;
  } catch {
    return UNAVAILABLE;
  }
}
