// Browser-side helpers for Herman, the employee assistant (HermanChat.jsx,
// the Herman tab in the chat window). Display-only: nothing here grants
// access, because Herman's API checks the employee's token
// (infrastructure/aws/modules/employees). This module stays tiny because the
// chat window loads on every page.

// True when this tab has an employee sign-in session (oidc-client-ts keeps
// it under an `oidc.user:` key), the same check AccountMenu uses. An expired
// session still counts: the Herman tab renews it or asks them to sign in.
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

// "Edit" on Herman's draft card opens the full form on Add Knowledge with the
// draft in it. The draft travels in sessionStorage and is removed as it's read.
const DRAFT_KEY = 'ae-rv-herman-draft';
const TYPES = new Set(['capability', 'faq', 'note']);

export function saveHermanDraft({ type, fields, reviewNote }) {
  try {
    sessionStorage.setItem(DRAFT_KEY, JSON.stringify({ type, fields, reviewNote: reviewNote || null }));
    return true;
  } catch {
    return false;
  }
}

// {type, fields, reviewNote} or null.
export function takeHermanDraft() {
  try {
    const raw = sessionStorage.getItem(DRAFT_KEY);
    sessionStorage.removeItem(DRAFT_KEY);
    const draft = JSON.parse(raw ?? 'null');
    if (!TYPES.has(draft?.type) || typeof draft.fields !== 'object' || draft.fields === null) return null;
    return {
      type: draft.type,
      fields: draft.fields,
      reviewNote: typeof draft.reviewNote === 'string' ? draft.reviewNote : null,
    };
  } catch {
    return null;
  }
}
