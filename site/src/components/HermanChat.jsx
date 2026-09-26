import { useEffect, useId, useRef, useState } from 'react';
import { assistantChat, getAssistantStatus, submitKnowledge } from '../lib/api.js';
import { currentUser, signIn } from '../lib/auth.js';
import { saveHermanDraft } from '../lib/herman.js';
import { TYPES, buildMarkdown, validate } from '../lib/knowledge.js';
import FormattedReply from './FormattedReply.jsx';
import { MarkdownView } from './KnowledgeForm.jsx';
import './HermanChat.css';

// The Herman tab of the chat window (ChatWidget.jsx), for signed-in
// employees only. It's loaded on demand, so customers never download it.
// Herman interviews the employee and drafts a knowledge entry that teaches
// Eddie. He only drafts: "Submit for review" sends the draft through the same
// POST /kb/entries as the Add Knowledge form, and an admin approves it on
// KBValidation before Eddie sees it. The message list and input reuse the
// chat window's .chat-widget__ styles so both tabs look the same.

// Must stay within Herman's request limits (modules/employees/lambda/herman.py),
// which reject anything larger with a 400.
const MAX_MESSAGES = 40;
const MAX_USER_CHARS = 2000;
const MAX_ASSISTANT_CHARS = 6000;
const COUNTER_FROM = 1600;

const STORAGE_KEY = 'ae-rv-kb-intake';
const SEED_OPENER = 'I want to teach Eddie about this.';
const SUBMITTED_TEXT = 'Submitted for review. An admin will check it before Eddie uses it.';
const OFF_TEXT = 'Herman is switched off right now.';

const EMPTY = { messages: [], draft: null, missing: [], reviewNote: null, seed: null, ready: false };

function loadChat() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? 'null');
    return saved && Array.isArray(saved.messages) ? { ...EMPTY, ...saved } : EMPTY;
  } catch {
    return EMPTY;
  }
}

function saveChat(chat) {
  try {
    if (chat.messages.length > 0) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(chat));
    else sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // Storage blocked: the chat still works, it just won't survive a reload.
  }
}

// `seed` is an Eddie exchange from "Teach Eddie about this": {question,
// reply, source}. Herman starts a new chat about it, then calls onSeedUsed.
export default function HermanChat({ seed, onSeedUsed }) {
  const [auth, setAuth] = useState('checking'); // checking | signedIn | signedOut
  // Herman's on/off switch (Feature Mgr): checking | on | off. The API enforces
  // it; this only lets the tab say so up front.
  const [herman, setHerman] = useState('checking');
  const [chat, setChat] = useState(loadChat);
  const [input, setInput] = useState('');
  const [sending, setSending] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const id = useId();
  const listRef = useRef(null);
  const inputRef = useRef(null);

  useEffect(() => {
    currentUser()
      .then((user) => setAuth(user ? 'signedIn' : 'signedOut'))
      .catch(() => setAuth('signedOut'));
  }, []);

  useEffect(() => {
    saveChat(chat);
  }, [chat]);

  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [chat, sending, notice]);

  useEffect(() => {
    if (auth === 'signedIn') checkSwitch();
  }, [auth]);

  useEffect(() => {
    if (auth === 'signedIn' && herman === 'on') inputRef.current?.focus();
  }, [auth, herman]);

  // From Eddie's "Teach Eddie about this": start a new chat about it. While
  // Herman is off, the exchange waits until he's back on.
  useEffect(() => {
    if (!seed || auth !== 'signedIn' || herman !== 'on') return;
    onSeedUsed();
    send(SEED_OPENER, { ...EMPTY, seed });
  }, [seed, auth, herman]);

  async function checkSwitch() {
    setHerman('checking');
    const token = await idToken();
    if (!token) return;
    const result = await getAssistantStatus(token);
    // If the check itself fails, show the chat: the API still refuses while
    // he's off, and the tab then says so.
    setHerman(result.status === 'ok' && result.data?.enabled === false ? 'off' : 'on');
  }

  // A fresh token for each call: currentUser() renews an expired one.
  async function idToken() {
    const user = await currentUser().catch(() => null);
    if (!user) setAuth('signedOut');
    return user?.id_token;
  }

  async function send(text, base = chat) {
    if (!text || sending) return;
    const messages = [...base.messages, { role: 'user', content: text }];
    setChat({ ...base, messages });
    setInput('');
    setSending(true);
    setError('');
    setNotice('');

    const token = await idToken();
    const result = token
      ? await assistantChat(token, {
          mode: 'knowledge',
          messages: messages.map(({ role, content }) => ({
            role,
            content: role === 'assistant' ? content.slice(0, MAX_ASSISTANT_CHARS) : content,
          })),
          draft: base.draft,
          seed: base.seed,
        })
      : { status: 'unauthorized' };
    setSending(false);

    if (result.status !== 'ok') {
      // Put the message back, so the conversation still alternates and
      // nothing they typed is lost.
      setChat(base);
      setInput(text);
      if (result.status === 'unauthorized') setAuth('signedOut');
      else if (result.status === 'off') setHerman('off');
      else setError(result.status === 'invalid' ? result.message : 'Herman can’t answer right now. Try again in a minute.');
      return;
    }
    const { reply, draft, ready, missing, reviewNote } = result.data;
    setChat({
      ...base,
      messages: [...messages, { role: 'assistant', content: reply }],
      // Herman sends null while he's still working out the kind of entry.
      draft: draft ?? base.draft,
      ready: Boolean(ready),
      missing: Array.isArray(missing) ? missing : [],
      // Kept once set, so the reviewer sees it even if a later turn omits it.
      reviewNote: reviewNote || base.reviewNote,
    });
    inputRef.current?.focus();
  }

  function startOver() {
    setChat(EMPTY);
    setError('');
    setNotice('');
    setInput('');
  }

  async function submit() {
    setSubmitting(true);
    setError('');
    const { type, fields } = chat.draft;
    const token = await idToken();
    const result = token
      ? await submitKnowledge(token, type, fields, {
          origin: 'chat',
          ...(chat.reviewNote ? { reviewNote: chat.reviewNote } : {}),
        })
      : { status: 'unauthorized' };
    setSubmitting(false);
    if (result.status === 'ok') {
      startOver();
      setNotice(SUBMITTED_TEXT);
    } else if (result.status !== 'unauthorized') {
      setError(result.status === 'invalid' ? result.message : 'Couldn’t submit. Please try again.');
    }
  }

  function editInForm() {
    if (saveHermanDraft(chat.draft ? { ...chat.draft, reviewNote: chat.reviewNote } : {})) {
      window.location.assign('/add-knowledge/');
    } else {
      setError('Couldn’t open the form. Check that this browser allows site storage.');
    }
  }

  if (auth === 'checking' || (auth === 'signedIn' && herman === 'checking')) {
    return <p className="chat-widget__state">Connecting…</p>;
  }
  if (auth === 'signedIn' && herman === 'off') {
    return (
      <div className="chat-widget__state herman-chat__off">
        <p>{OFF_TEXT}</p>
        <p className="herman-chat__off-note">
          An admin can turn him back on in Feature Mgr. Your conversation is kept. To add knowledge now, use the Add
          Knowledge form.
        </p>
        <button type="button" className="chat-widget__send" onClick={checkSwitch}>
          Check again
        </button>
      </div>
    );
  }
  if (auth === 'signedOut') {
    return (
      <div className="chat-widget__state herman-chat__signin">
        <p>Your employee sign-in has expired. Sign in again to chat with Herman.</p>
        <button type="button" className="chat-widget__send" onClick={() => signIn()}>
          Sign in
        </button>
      </div>
    );
  }

  const full = chat.messages.length + 1 > MAX_MESSAGES;

  return (
    <>
      <div className="herman-chat__bar">
        <span>Herman helps you teach Eddie. An admin reviews every entry.</span>
        {chat.messages.length > 0 && (
          <button type="button" className="chat-widget__text-button" onClick={startOver} disabled={sending || submitting}>
            Start over
          </button>
        )}
      </div>

      <div className="chat-widget__messages" ref={listRef} aria-live="polite">
        {chat.seed && (
          <div className="herman-chat__seed">
            <p className="herman-chat__label">From a chat with Eddie</p>
            <p>
              <strong>Customer:</strong> {chat.seed.question}
            </p>
            <p>
              <strong>Eddie:</strong> {chat.seed.reply}
            </p>
          </div>
        )}
        {chat.messages.length === 0 && !notice && (
          <p className="chat-widget__hint">
            Tell Herman what you want Eddie to know, for example: “Customers keep asking whether they can run the AC
            on solar.”
          </p>
        )}
        {notice && <p className="herman-chat__notice">{notice}</p>}
        {chat.messages.map((message, i) => (
          <div key={i} className={`chat-widget__message chat-widget__message--${message.role}`}>
            {message.role === 'assistant' ? <FormattedReply text={message.content} /> : <p>{message.content}</p>}
          </div>
        ))}
        {sending && (
          <p className="chat-widget__typing">
            <span className="chat-widget__sr-only">Herman is typing</span>
            <span aria-hidden="true">•••</span>
          </p>
        )}
        {chat.draft && !sending && (
          <DraftCard
            chat={chat}
            submitting={submitting}
            onSubmit={submit}
            onEdit={editInForm}
          />
        )}
        {error && (
          <p className="herman-chat__error" role="alert">
            {error}
          </p>
        )}
      </div>

      {full ? (
        <p className="chat-widget__state">This conversation is as long as Herman can follow. Submit the draft, or start over.</p>
      ) : (
        <form
          className="chat-widget__form"
          onSubmit={(event) => {
            event.preventDefault();
            send(input.trim());
          }}
        >
          <label className="chat-widget__sr-only" htmlFor={`${id}-input`}>
            Your message to Herman
          </label>
          <textarea
            id={`${id}-input`}
            ref={inputRef}
            className="chat-widget__input"
            rows={2}
            maxLength={MAX_USER_CHARS}
            value={input}
            onChange={(event) => setInput(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                send(input.trim());
              }
            }}
            disabled={sending || submitting}
            placeholder="Type your answer…"
          />
          <div className="chat-widget__form-row">
            {input.length >= COUNTER_FROM && (
              <span className="chat-widget__counter">
                {input.length}/{MAX_USER_CHARS}
              </span>
            )}
            <button type="submit" className="chat-widget__send" disabled={sending || submitting || !input.trim()}>
              Send
            </button>
          </div>
        </form>
      )}
    </>
  );
}

// Herman's current draft, shown after the latest message and updated each
// turn. "Submit for review" is enabled once the draft passes the same checks
// the server applies; "Edit" opens the full form with the draft in it.
function DraftCard({ chat, submitting, onSubmit, onEdit }) {
  const [open, setOpen] = useState(false);
  const { type, fields } = chat.draft;
  const problem = validate(type, fields);
  const needed = chat.missing.length > 0 ? chat.missing : problem ? [problem] : [];

  return (
    <section className="herman-chat__card" aria-label="Draft entry">
      <p className="herman-chat__label">Draft · {TYPES[type]?.label ?? type}</p>
      <p className="herman-chat__title">{fields.title?.trim() || 'Untitled'}</p>

      {needed.length > 0 ? (
        <div className="herman-chat__needed">
          <p>Still needed:</p>
          <ul>
            {needed.map((item) => (
              <li key={item}>{item}</li>
            ))}
          </ul>
        </div>
      ) : (
        <p className="herman-chat__ready">{chat.ready ? 'Herman thinks this is ready.' : 'Complete.'} Check it, then submit.</p>
      )}
      {chat.reviewNote && (
        <p className="herman-chat__note">
          <strong>Note for the reviewer:</strong> {chat.reviewNote}
        </p>
      )}

      <button type="button" className="chat-widget__text-button" aria-expanded={open} onClick={() => setOpen(!open)}>
        {open ? 'Hide the draft' : 'Show the draft'}
      </button>
      {open && <MarkdownView markdown={buildMarkdown(type, fields)} />}

      <div className="herman-chat__actions">
        <button type="button" className="chat-widget__send" disabled={Boolean(problem) || submitting} onClick={onSubmit}>
          {submitting ? 'Submitting…' : 'Submit for review'}
        </button>
        <button type="button" className="chat-widget__text-button" disabled={submitting} onClick={onEdit}>
          Edit in the form
        </button>
      </div>
    </section>
  );
}
