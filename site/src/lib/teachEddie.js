// The Eddie -> Herman handoff. A signed-in employee who sees a weak answer in
// Eddie's chat widget clicks "Teach Eddie about this". The widget saves the
// exchange here, and Herman (KnowledgeChat on /add-knowledge/) picks it up
// and starts the interview from that gap.
//
// Browser-only and display-only: the link grants nothing, because Herman's API
// requires a valid employee token (infrastructure/aws/modules/employees). This
// module stays tiny because the chat widget loads on every page.

const SEED_KEY = 'ae-rv-herman-seed';
const SOURCES = new Set(['knowledge_base', 'both', 'general']);

// Herman's API limits for a seed (the same as Eddie's chat API).
const MAX_QUESTION = 500;
const MAX_REPLY = 2500;

// True when this tab has an employee sign-in session (oidc-client-ts keeps
// it under an `oidc.user:` key), the same check AccountMenu uses. An expired
// session still counts: Add Knowledge renews it or asks them to sign in.
export function hasEmployeeSession() {
  try {
    for (let i = 0; i < sessionStorage.length; i++) {
      if (sessionStorage.key(i)?.startsWith('oidc.user:')) return true;
    }
  } catch {
    // Storage blocked: treat as signed out.
  }
  return false;
}

export function saveTeachSeed({ question, reply, source }) {
  try {
    sessionStorage.setItem(
      SEED_KEY,
      JSON.stringify({
        question: String(question).slice(0, MAX_QUESTION),
        reply: String(reply).slice(0, MAX_REPLY),
        source: SOURCES.has(source) ? source : 'general',
      }),
    );
  } catch {
    // Storage blocked: Herman just starts without the Eddie chat.
  }
}

// The saved exchange, removed as it's read so it seeds only one chat; or
// null when there isn't a usable one.
export function takeTeachSeed() {
  try {
    const raw = sessionStorage.getItem(SEED_KEY);
    sessionStorage.removeItem(SEED_KEY);
    const seed = JSON.parse(raw ?? 'null');
    if (typeof seed?.question !== 'string' || typeof seed?.reply !== 'string') return null;
    if (!seed.question.trim() || !seed.reply.trim() || !SOURCES.has(seed.source)) return null;
    return { question: seed.question, reply: seed.reply, source: seed.source };
  } catch {
    return null;
  }
}
