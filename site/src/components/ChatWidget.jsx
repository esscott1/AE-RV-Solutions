import { Suspense, lazy, useEffect, useId, useRef, useState } from 'react';
import { chatConfigured, getChatStatus, sendChatMessage } from '../lib/api.js';
import { hasEmployeeSession } from '../lib/herman.js';
import FormattedReply from './FormattedReply.jsx';
import './ChatWidget.css';

// Herman, the employee assistant, is a second tab for signed-in employees.
// Loaded on demand, so customers never download his code.
const HermanChat = lazy(() => import('./HermanChat.jsx'));

// Must stay within the chat API's request limits (modules/chatbot
// variables), which reject anything larger with a 400.
const MAX_MESSAGES = 8;
const MAX_USER_CHARS = 500;
const MAX_ASSISTANT_CHARS = 2500;
const COUNTER_FROM = 400;

const STORAGE_KEY = 'ae-rv-chat';
const CONVERSATION_ID_KEY = 'ae-rv-chat-id';
// The window size the visitor last picked: 'compact' or 'expanded' (the
// expand button), or {width, height} in pixels (dragged with the corner
// handle).
const SIZE_KEY = 'ae-rv-chat-size';
// Dragging can't make the window smaller than this (px).
const MIN_WIDTH = 300;
const MIN_HEIGHT = 320;
// Arrow keys on the handle resize by this much (px).
const KEY_STEP = 40;
const OFFLINE_TEXT = 'Chat is offline right now. Please contact us directly.';
const NOTICE_TEXT =
  'AI assistant. For electrical or battery hazards, contact a technician. Automated or bulk access is not permitted.';
// Shown small under the message box. Chats are saved as transcripts
// (modules/chatbot/transcripts.tf); "train Eddie" means improving his answers
// and knowledge from real questions, not training an AI model.
const PRIVACY_TEXT =
  "Chats are saved for 30 days to help train Eddie. We never save your name, IP address, or location, so please don't type personal details.";
const SAFETY_ROUTES = new Set(['safety_referral', 'emergency']);

// Shown under answers so visitors know where each one came from. Eddie
// doesn't search the web: "general knowledge" is the AI model's own.
const SOURCE_CAPTIONS = {
  knowledge_base: "From A&E's knowledge base",
  both: "From A&E's knowledge base and general knowledge",
  general: 'From general knowledge',
};

// Signed-in employees get a link under each answer that switches to the
// Herman tab with this exchange, to teach Eddie what he was missing. A
// "general" answer means no A&E knowledge matched: that's the gap to fill.
const TEACH_TEXT = {
  general: 'Eddie had no A&E info for this. Teach him with Herman',
  default: 'Teach Eddie about this',
};

// The last messages that fit the API's limits: at most MAX_MESSAGES,
// starting with a customer message, with long assistant replies cut to
// size.
function requestWindow(messages) {
  let recent = messages.slice(-MAX_MESSAGES);
  while (recent.length > 0 && recent[0].role !== 'user') recent = recent.slice(1);
  return recent.map(({ role, content }) => ({
    role,
    content: role === 'assistant' ? content.slice(0, MAX_ASSISTANT_CHARS) : content,
  }));
}

function loadConversation() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? '[]');
    return Array.isArray(saved) ? saved : [];
  } catch {
    return [];
  }
}

// A random ID per conversation, so saved transcripts can be grouped. It
// lives only in this tab's sessionStorage (no cookie), isn't derived from
// the visitor, and is replaced on "Start over". Without crypto.randomUUID
// (very old browsers), no ID is sent and each exchange stands alone.
function newConversationId() {
  return typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : '';
}

function loadConversationId() {
  try {
    const saved = sessionStorage.getItem(CONVERSATION_ID_KEY);
    if (saved) return saved;
  } catch {
    // Storage blocked: a fresh ID per page load is fine.
  }
  return newConversationId();
}

function saveConversationId(id) {
  try {
    if (id) sessionStorage.setItem(CONVERSATION_ID_KEY, id);
  } catch {
    // Storage blocked: the ID just won't survive navigation.
  }
}

function loadSize() {
  try {
    const saved = JSON.parse(sessionStorage.getItem(SIZE_KEY) ?? 'null');
    if (saved === 'expanded' || saved === 'compact') return saved;
    if (Number.isFinite(saved?.width) && Number.isFinite(saved?.height)) {
      return { width: saved.width, height: saved.height };
    }
  } catch {
    // Storage blocked or unreadable: use the default size.
  }
  return null;
}

function saveSize(size) {
  try {
    if (size) sessionStorage.setItem(SIZE_KEY, JSON.stringify(size));
  } catch {
    // Storage blocked: the size just resets on the next page.
  }
}

// A dragged size, kept within the minimum and the space the window has on
// screen (it sits 1.25rem from the right and above the launcher).
function clampSize(width, height) {
  const maxWidth = Math.max(MIN_WIDTH, window.innerWidth - 40);
  const maxHeight = Math.max(MIN_HEIGHT, window.innerHeight - 112);
  return {
    width: Math.round(Math.min(maxWidth, Math.max(MIN_WIDTH, width))),
    height: Math.round(Math.min(maxHeight, Math.max(MIN_HEIGHT, height))),
  };
}

function saveConversation(messages) {
  try {
    if (messages.length > 0) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(messages));
    else sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // Storage blocked (private mode, disabled cookies): the chat still
    // works, it just won't survive navigation.
  }
}

export default function ChatWidget() {
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState('idle'); // idle | checking | on | off
  // Restored from sessionStorage as the initial state. The server render
  // gets [] (loadConversation catches the missing sessionStorage), and that
  // can't cause a hydration mismatch: the conversation is only rendered once
  // the panel is opened.
  const [messages, setMessages] = useState(loadConversation);
  const [conversationId, setConversationId] = useState(loadConversationId);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  // Checked when the panel opens: the conversation (and the tabs) only
  // render then, so the server render never needs it.
  const [employee, setEmployee] = useState(false);
  const [tab, setTab] = useState('eddie'); // eddie | herman (employees only)
  // An Eddie exchange handed to Herman by "Teach Eddie about this".
  const [teachSeed, setTeachSeed] = useState(null);
  // null until the visitor resizes the window. Until then, Herman's tab
  // opens large (his drafts need the room) and Eddie's stays compact.
  const [size, setSize] = useState(loadSize);
  const panelRef = useRef(null);
  const dragRef = useRef(null);

  const panelId = useId();
  const launcherRef = useRef(null);
  const closeRef = useRef(null);
  const inputRef = useRef(null);
  const listRef = useRef(null);

  useEffect(() => {
    saveConversation(messages);
  }, [messages]);

  useEffect(() => {
    saveConversationId(conversationId);
  }, [conversationId]);

  useEffect(() => {
    saveSize(size);
  }, [size]);

  // A dragged size reaches the stylesheet as two CSS variables
  // (--chat-widget-width/-height, used by .chat-widget__panel--sized): a size
  // the visitor drags to can't be written in the stylesheet ahead of time.
  useEffect(() => {
    const panel = panelRef.current;
    if (!panel) return;
    if (size && typeof size === 'object') {
      panel.style.setProperty('--chat-widget-width', `${size.width}px`);
      panel.style.setProperty('--chat-widget-height', `${size.height}px`);
    } else {
      panel.style.removeProperty('--chat-widget-width');
      panel.style.removeProperty('--chat-widget-height');
    }
  }, [open, size]);

  // Keep the newest message (or the typing indicator) in view.
  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [messages, sending, status]);

  // The on/off check runs each time the panel opens, never on page load, so
  // browsing the site doesn't call the API.
  useEffect(() => {
    if (!open) return;
    const signedIn = hasEmployeeSession();
    setEmployee(signedIn);
    if (!signedIn) setTab('eddie');
    let cancelled = false;
    setStatus('checking');
    getChatStatus().then((enabled) => {
      if (!cancelled) setStatus(enabled ? 'on' : 'off');
    });
    return () => {
      cancelled = true;
    };
  }, [open]);

  useEffect(() => {
    if (!open || tab !== 'eddie') return;
    if (status === 'on') inputRef.current?.focus();
    else closeRef.current?.focus();
  }, [open, status, tab]);

  if (!chatConfigured) return null;

  function close() {
    setOpen(false);
    launcherRef.current?.focus();
  }

  async function send() {
    const text = draft.trim();
    if (!text || sending) return;

    const next = [...messages, { role: 'user', content: text }];
    setMessages(next);
    setDraft('');
    setSending(true);

    const { route, reply, source } = await sendChatMessage(requestWindow(next), conversationId);
    setMessages([...next, { role: 'assistant', content: reply, route, source }]);
    setSending(false);
    // Switched off while the conversation was open.
    if (route === 'offline') setStatus('off');
  }

  function onInputKeyDown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      send();
    }
  }

  function onPanelKeyDown(event) {
    if (event.key === 'Escape') close();
  }

  // The corner handle: the window is pinned bottom-right, so dragging the
  // top-left corner up or left makes it bigger. During a drag the variables
  // are set directly; the final size is saved when the pointer is released.
  function onGripPointerDown(event) {
    const panel = panelRef.current;
    if (!panel || event.button !== 0) return;
    event.preventDefault();
    const rect = panel.getBoundingClientRect();
    dragRef.current = { x: event.clientX, y: event.clientY, width: rect.width, height: rect.height };
    event.currentTarget.setPointerCapture(event.pointerId);
    setSize(clampSize(rect.width, rect.height));
  }

  function onGripPointerMove(event) {
    const drag = dragRef.current;
    if (!drag) return;
    const next = clampSize(drag.width + drag.x - event.clientX, drag.height + drag.y - event.clientY);
    panelRef.current?.style.setProperty('--chat-widget-width', `${next.width}px`);
    panelRef.current?.style.setProperty('--chat-widget-height', `${next.height}px`);
    drag.last = next;
  }

  function onGripPointerUp() {
    const drag = dragRef.current;
    dragRef.current = null;
    if (drag?.last) setSize(drag.last);
  }

  function onGripKeyDown(event) {
    const deltas = { ArrowLeft: [KEY_STEP, 0], ArrowRight: [-KEY_STEP, 0], ArrowUp: [0, KEY_STEP], ArrowDown: [0, -KEY_STEP] };
    const delta = deltas[event.key];
    const rect = panelRef.current?.getBoundingClientRect();
    if (!delta || !rect) return;
    event.preventDefault();
    setSize(clampSize(rect.width + delta[0], rect.height + delta[1]));
  }

  const eddieTab = tab === 'eddie';
  const dragged = Boolean(size) && typeof size === 'object';
  const expanded = size ? size === 'expanded' : !eddieTab;
  const sizeClass = dragged ? ' chat-widget__panel--sized' : expanded ? ' chat-widget__panel--expanded' : '';

  return (
    <div className="chat-widget">
      {open && (
        <div
          id={panelId}
          ref={panelRef}
          className={`chat-widget__panel${sizeClass}`}
          role="dialog"
          aria-label="A&E RV Solutions assistant"
          onKeyDown={onPanelKeyDown}
        >
          <button
            type="button"
            className="chat-widget__grip"
            aria-label="Resize the chat window: drag, or use the arrow keys"
            title="Drag to resize"
            onPointerDown={onGripPointerDown}
            onPointerMove={onGripPointerMove}
            onPointerUp={onGripPointerUp}
            onPointerCancel={onGripPointerUp}
            onKeyDown={onGripKeyDown}
          />
          <div className="chat-widget__header">
            {employee ? (
              <div className="chat-widget__tabs" role="tablist" aria-label="Assistants">
                {[
                  ['eddie', 'Eddie'],
                  ['herman', 'Herman'],
                ].map(([key, label]) => (
                  <button
                    key={key}
                    type="button"
                    role="tab"
                    className="chat-widget__tab"
                    aria-selected={tab === key}
                    onClick={() => setTab(key)}
                  >
                    {label}
                  </button>
                ))}
              </div>
            ) : (
              <span className="chat-widget__title">A&amp;E RV Solutions assistant</span>
            )}
            {eddieTab && messages.length > 0 && status === 'on' && (
              <button
                type="button"
                className="chat-widget__text-button"
                onClick={() => {
                  setMessages([]);
                  setConversationId(newConversationId());
                }}
                disabled={sending}
              >
                Start over
              </button>
            )}
            <button
              type="button"
              className="chat-widget__close chat-widget__size"
              onClick={() => setSize(expanded || dragged ? 'compact' : 'expanded')}
              aria-label={expanded || dragged ? 'Make the chat window small' : 'Make the chat window large'}
              aria-pressed={expanded || dragged}
              title={expanded || dragged ? 'Small' : 'Large'}
            >
              <span aria-hidden="true">{expanded || dragged ? '⤡' : '⤢'}</span>
            </button>
            <button
              type="button"
              ref={closeRef}
              className="chat-widget__close"
              onClick={close}
              aria-label="Close chat"
            >
              ×
            </button>
          </div>

          {!eddieTab && (
            <Suspense fallback={<p className="chat-widget__state">Connecting…</p>}>
              <HermanChat seed={teachSeed} onSeedUsed={() => setTeachSeed(null)} />
            </Suspense>
          )}

          {eddieTab && status === 'checking' && <p className="chat-widget__state">Connecting…</p>}

          {eddieTab && status === 'off' && <p className="chat-widget__state">{OFFLINE_TEXT}</p>}

          {eddieTab && status === 'on' && (
            <>
              <p className="chat-widget__notice">{NOTICE_TEXT}</p>

              <div className="chat-widget__messages" ref={listRef} aria-live="polite">
                {messages.length === 0 && (
                  <p className="chat-widget__hint">
                    Ask about RV solar, inverters, troubleshooting, or our services.
                  </p>
                )}
                {messages.map((message, i) => {
                  const safety = message.role === 'assistant' && SAFETY_ROUTES.has(message.route);
                  return (
                    <div
                      key={i}
                      className={[
                        'chat-widget__message',
                        `chat-widget__message--${message.role}`,
                        safety && 'chat-widget__message--safety',
                      ]
                        .filter(Boolean)
                        .join(' ')}
                    >
                      {safety && (
                        <p className="chat-widget__safety-label">
                          <span aria-hidden="true">⚠</span> Safety notice
                        </p>
                      )}
                      {message.role === 'assistant' ? (
                        <>
                          <FormattedReply text={message.content} />
                          {message.route === 'answer' && SOURCE_CAPTIONS[message.source] && (
                            <p className="chat-widget__source">{SOURCE_CAPTIONS[message.source]}</p>
                          )}
                          {employee && message.route === 'answer' && messages[i - 1]?.role === 'user' && (
                            <button
                              type="button"
                              className="chat-widget__teach"
                              onClick={() => {
                                setTeachSeed({
                                  question: messages[i - 1].content,
                                  reply: message.content,
                                  source: message.source,
                                });
                                setTab('herman');
                              }}
                            >
                              {TEACH_TEXT[message.source] ?? TEACH_TEXT.default} →
                            </button>
                          )}
                        </>
                      ) : (
                        <p>{message.content}</p>
                      )}
                    </div>
                  );
                })}
                {sending && (
                  <p className="chat-widget__typing">
                    <span className="chat-widget__sr-only">The assistant is typing</span>
                    <span aria-hidden="true">•••</span>
                  </p>
                )}
              </div>

              <form
                className="chat-widget__form"
                onSubmit={(event) => {
                  event.preventDefault();
                  send();
                }}
              >
                <label className="chat-widget__sr-only" htmlFor={`${panelId}-input`}>
                  Your message
                </label>
                <textarea
                  id={`${panelId}-input`}
                  ref={inputRef}
                  className="chat-widget__input"
                  rows={2}
                  maxLength={MAX_USER_CHARS}
                  value={draft}
                  onChange={(event) => setDraft(event.target.value)}
                  onKeyDown={onInputKeyDown}
                  disabled={sending}
                  placeholder="Type your question…"
                />
                <div className="chat-widget__form-row">
                  {draft.length >= COUNTER_FROM && (
                    <span className="chat-widget__counter">
                      {draft.length}/{MAX_USER_CHARS}
                    </span>
                  )}
                  <button
                    type="submit"
                    className="chat-widget__send"
                    disabled={sending || draft.trim() === ''}
                  >
                    Send
                  </button>
                </div>
                <p className="chat-widget__privacy">{PRIVACY_TEXT}</p>
              </form>
            </>
          )}
        </div>
      )}

      <button
        type="button"
        ref={launcherRef}
        className="chat-widget__launcher"
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        onClick={() => (open ? close() : setOpen(true))}
      >
        {open ? 'Close chat' : 'Chat with us'}
      </button>
    </div>
  );
}
