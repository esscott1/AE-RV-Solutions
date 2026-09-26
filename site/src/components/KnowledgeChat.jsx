import { useEffect, useId, useRef, useState } from 'react';
import { assistantChat, submitKnowledge } from '../lib/api.js';
import { TYPES, validate } from '../lib/knowledge.js';
import { takeTeachSeed } from '../lib/teachEddie.js';
import FormattedReply from './FormattedReply.jsx';
import { KnowledgeForm, Preview } from './KnowledgeForm.jsx';
import './KnowledgeChat.css';

// Add Knowledge's chat mode: Herman interviews the employee and drafts the
// entry. Herman only drafts: "Submit for review" sends the draft through
// the same POST /kb/entries as the form, and an admin approves it on
// KBValidation before Eddie sees it.

// Must stay within Herman's request limits (modules/employees/lambda/herman.py),
// which reject anything larger with a 400.
const MAX_MESSAGES = 40;
const MAX_USER_CHARS = 2000;
const MAX_ASSISTANT_CHARS = 6000;
const COUNTER_FROM = 1600;

const STORAGE_KEY = 'ae-rv-kb-intake';
const SEED_OPENER = 'I want to teach Eddie about this.';
const SOURCE_TEXT = {
  general: 'Eddie answered from general knowledge: no A&E knowledge matched.',
  knowledge_base: 'Eddie answered from A&E’s knowledge.',
  both: 'Eddie answered from A&E’s knowledge and general knowledge.',
};

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

export default function KnowledgeChat({ token, onSubmitted }) {
  // Only rendered once the employee is signed in (inside Add Knowledge's
  // Gate), so sessionStorage is available on first render.
  const [chat, setChat] = useState(loadChat);
  const [input, setInput] = useState('');
  const [sending, setSending] = useState(false);
  const [editing, setEditing] = useState(false);
  const [edited, setEdited] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');

  const id = useId();
  const listRef = useRef(null);
  const inputRef = useRef(null);

  useEffect(() => {
    saveChat(chat);
  }, [chat]);

  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [chat.messages, sending]);

  // Arriving from Eddie's "Teach Eddie about this" link: start a new chat
  // about that exchange.
  useEffect(() => {
    const seed = takeTeachSeed();
    if (seed) send(SEED_OPENER, { ...EMPTY, seed });
  }, []);

  async function send(text, base = chat) {
    if (!text || sending) return;
    const messages = [...base.messages, { role: 'user', content: text }];
    setChat({ ...base, messages });
    setInput('');
    setSending(true);
    setError('');

    const result = await assistantChat(token, {
      mode: 'knowledge',
      messages: messages.map(({ role, content }) => ({
        role,
        content: role === 'assistant' ? content.slice(0, MAX_ASSISTANT_CHARS) : content,
      })),
      draft: base.draft,
      seed: base.seed,
    });
    setSending(false);

    if (result.status !== 'ok') {
      // Put the message back, so the conversation still alternates and
      // nothing they typed is lost.
      setChat(base);
      setInput(text);
      setError(
        result.status === 'invalid'
          ? result.message
          : result.status === 'unauthorized'
            ? 'Your sign-in has expired. Reload the page to sign in again.'
            : 'Herman can’t answer right now. Try again in a minute.',
      );
      return;
    }
    const { reply, draft, ready, missing, reviewNote } = result.data;
    setChat({
      ...base,
      messages: [...messages, { role: 'assistant', content: reply }],
      // Herman sends null while he's still working out the kind of entry;
      // keep what's there rather than lose the employee's edits.
      draft: draft ?? base.draft,
      ready: Boolean(ready),
      missing: Array.isArray(missing) ? missing : [],
      reviewNote: reviewNote || base.reviewNote,
    });
    setEdited(false);
    inputRef.current?.focus();
  }

  function startOver() {
    setChat(EMPTY);
    setEditing(false);
    setEdited(false);
    setError('');
    setInput('');
  }

  function editDraft(fields) {
    setChat({ ...chat, draft: { ...chat.draft, fields } });
    setEdited(true);
  }

  async function submit() {
    setSubmitting(true);
    setError('');
    const { type, fields } = chat.draft;
    const result = await submitKnowledge(token, type, fields, {
      origin: 'chat',
      ...(chat.reviewNote ? { reviewNote: chat.reviewNote } : {}),
    });
    setSubmitting(false);
    if (result.status === 'ok') {
      startOver();
      onSubmitted();
    } else {
      setError(result.status === 'invalid' ? result.message : 'Couldn’t submit. Please try again, or sign in again.');
    }
  }

  const draft = chat.draft;
  const problem = draft ? validate(draft.type, draft.fields) : '';
  const canSubmit = Boolean(draft) && !problem && !sending && !submitting;
  // Herman's checklist is for the draft he returned. After hand edits, the
  // form's own check takes over until the next turn.
  const checklist = edited ? (problem ? [problem] : []) : chat.missing;
  // No room for another message from the employee.
  const full = chat.messages.length + 1 > MAX_MESSAGES;

  return (
    <div className="knowledge-chat">
      <section className="knowledge-chat__conversation" aria-label="Chat with Herman">
        <div className="knowledge-chat__head">
          <p className="knowledge-chat__intro">
            <strong>Herman</strong> collects what you know and turns it into an entry that teaches Eddie.
          </p>
          {chat.messages.length > 0 && (
            <button
              type="button"
              className="knowledge__button knowledge__button--quiet"
              onClick={startOver}
              disabled={sending || submitting}
            >
              Start over
            </button>
          )}
        </div>

        {chat.seed && (
          <div className="knowledge-chat__seed">
            <p className="knowledge-chat__seed-title">From a chat with Eddie</p>
            <p>
              <strong>Customer:</strong> {chat.seed.question}
            </p>
            <p>
              <strong>Eddie:</strong> {chat.seed.reply}
            </p>
            <p className="knowledge__muted">{SOURCE_TEXT[chat.seed.source]}</p>
          </div>
        )}

        <div className="knowledge-chat__messages" ref={listRef} aria-live="polite">
          {chat.messages.length === 0 && (
            <p className="knowledge__muted">
              Tell Herman what you want Eddie to know, for example: “Customers keep asking whether they can run the
              AC on solar.”
            </p>
          )}
          {chat.messages.map((message, i) => (
            <div key={i} className={`knowledge-chat__message knowledge-chat__message--${message.role}`}>
              {message.role === 'assistant' ? <FormattedReply text={message.content} /> : <p>{message.content}</p>}
            </div>
          ))}
          {sending && (
            <p className="knowledge-chat__typing">
              <span className="knowledge__sr-only">Herman is typing</span>
              <span aria-hidden="true">•••</span>
            </p>
          )}
        </div>

        {full ? (
          <p className="knowledge__muted">
            This conversation is as long as Herman can follow. Submit the draft, or start over.
          </p>
        ) : (
          <form
            className="knowledge-chat__form"
            onSubmit={(event) => {
              event.preventDefault();
              send(input.trim());
            }}
          >
            <label className="knowledge__sr-only" htmlFor={`${id}-input`}>
              Your message to Herman
            </label>
            <textarea
              id={`${id}-input`}
              ref={inputRef}
              className="knowledge__textarea knowledge-chat__input"
              rows={3}
              maxLength={MAX_USER_CHARS}
              value={input}
              disabled={sending || submitting}
              onChange={(event) => setInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' && !event.shiftKey) {
                  event.preventDefault();
                  send(input.trim());
                }
              }}
              placeholder="Type your answer…"
            />
            <div className="knowledge-chat__form-row">
              {input.length >= COUNTER_FROM && (
                <span className="knowledge__hint">
                  {input.length}/{MAX_USER_CHARS}
                </span>
              )}
              <button type="submit" className="knowledge__button" disabled={sending || submitting || !input.trim()}>
                Send
              </button>
            </div>
          </form>
        )}
      </section>

      <section className="knowledge-chat__draft" aria-label="Draft entry">
        <p className="knowledge-chat__draft-title">
          Draft{draft ? `: ${TYPES[draft.type]?.label ?? draft.type}` : ''}
        </p>
        {!draft && <p className="knowledge__muted">Herman builds the entry here as you talk.</p>}

        {draft && (
          <>
            {editing ? (
              <KnowledgeForm type={draft.type} fields={draft.fields} onChange={editDraft} disabled={submitting} />
            ) : (
              <Preview type={draft.type} fields={draft.fields} />
            )}
            <button
              type="button"
              className="knowledge__button knowledge__button--quiet"
              onClick={() => setEditing(!editing)}
              disabled={sending || submitting}
            >
              {editing ? 'Show the preview' : 'Edit by hand'}
            </button>

            {checklist.length > 0 && (
              <div className="knowledge-chat__missing">
                <p className="knowledge__label">Still needed</p>
                <ul>
                  {checklist.map((item) => (
                    <li key={item}>{item}</li>
                  ))}
                </ul>
              </div>
            )}
            {chat.reviewNote && (
              <p className="knowledge-chat__note">
                <strong>Note for the reviewer:</strong> {chat.reviewNote}
              </p>
            )}
            {chat.ready && !edited && !problem && (
              <p className="knowledge__muted">Herman thinks this is ready. Check it over, then submit.</p>
            )}
            <button type="button" className="knowledge__button" disabled={!canSubmit} onClick={submit}>
              {submitting ? 'Submitting…' : 'Submit for review'}
            </button>
          </>
        )}

        {error && (
          <p className="knowledge__message knowledge__message--error" role="alert">
            {error}
          </p>
        )}
      </section>
    </div>
  );
}
