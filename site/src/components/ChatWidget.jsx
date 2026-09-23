import { Fragment, useEffect, useId, useRef, useState } from 'react';
import { chatConfigured, getChatStatus, sendChatMessage } from '../lib/api.js';
import './ChatWidget.css';

// Must stay within the chat API's request limits (modules/chatbot
// variables), which reject anything larger with a 400.
const MAX_MESSAGES = 8;
const MAX_USER_CHARS = 500;
const MAX_ASSISTANT_CHARS = 2500;
const COUNTER_FROM = 400;

const STORAGE_KEY = 'ae-rv-chat';
const OFFLINE_TEXT = 'Chat is offline right now. Please contact A&E RV Solutions directly.';
const NOTICE_TEXT =
  "AI assistant. For electrical or battery hazards, contact a technician. Please don't share personal information. Automated or bulk access is not permitted.";
const SAFETY_ROUTES = new Set(['safety_referral', 'emergency']);

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

function saveConversation(messages) {
  try {
    if (messages.length > 0) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(messages));
    else sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // Storage blocked (private mode, disabled cookies): the chat still
    // works, it just won't survive navigation.
  }
}

// Renders the small markdown subset the model uses (**bold**, "- " or
// "1. " lists, line breaks) as React elements. Model output is never
// parsed as HTML, so it can't inject markup.
function inline(text) {
  return text.split(/\*\*(.+?)\*\*/g).map((part, i) =>
    i % 2 === 1 ? <strong key={i}>{part}</strong> : <Fragment key={i}>{part}</Fragment>,
  );
}

function FormattedReply({ text }) {
  const blocks = [];
  for (const line of text.split('\n')) {
    const bullet = line.match(/^\s*[-*•]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
    const item = bullet ?? numbered;
    const listType = bullet ? 'ul' : 'ol';
    const last = blocks[blocks.length - 1];

    if (item) {
      if (last?.type === listType) last.items.push(item[1]);
      else blocks.push({ type: listType, items: [item[1]] });
    } else if (line.trim() === '') {
      blocks.push({ type: 'break' });
    } else if (last?.type === 'p') {
      last.lines.push(line);
    } else {
      blocks.push({ type: 'p', lines: [line] });
    }
  }

  return blocks.map((block, i) => {
    if (block.type === 'break') return null;
    if (block.type === 'p') {
      return (
        <p key={i}>
          {block.lines.map((line, j) => (
            <Fragment key={j}>
              {j > 0 && <br />}
              {inline(line)}
            </Fragment>
          ))}
        </p>
      );
    }
    const List = block.type;
    return (
      <List key={i}>
        {block.items.map((itemText, j) => (
          <li key={j}>{inline(itemText)}</li>
        ))}
      </List>
    );
  });
}

export default function ChatWidget() {
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState('idle'); // idle | checking | on | off
  // Restored from sessionStorage as the initial state. The server render
  // gets [] (loadConversation catches the missing sessionStorage), and that
  // can't cause a hydration mismatch: the conversation is only rendered once
  // the panel is opened.
  const [messages, setMessages] = useState(loadConversation);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);

  const panelId = useId();
  const launcherRef = useRef(null);
  const closeRef = useRef(null);
  const inputRef = useRef(null);
  const listRef = useRef(null);

  useEffect(() => {
    saveConversation(messages);
  }, [messages]);

  // Keep the newest message (or the typing indicator) in view.
  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [messages, sending, status]);

  // The on/off check runs each time the panel opens, never on page load, so
  // browsing the site doesn't call the API.
  useEffect(() => {
    if (!open) return;
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
    if (!open) return;
    if (status === 'on') inputRef.current?.focus();
    else closeRef.current?.focus();
  }, [open, status]);

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

    const { route, reply } = await sendChatMessage(requestWindow(next));
    setMessages([...next, { role: 'assistant', content: reply, route }]);
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

  return (
    <div className="chat-widget">
      {open && (
        <div
          id={panelId}
          className="chat-widget__panel"
          role="dialog"
          aria-label="A&E RV Solutions assistant"
          onKeyDown={onPanelKeyDown}
        >
          <div className="chat-widget__header">
            <span className="chat-widget__title">A&amp;E RV Solutions assistant</span>
            {messages.length > 0 && status === 'on' && (
              <button
                type="button"
                className="chat-widget__text-button"
                onClick={() => setMessages([])}
                disabled={sending}
              >
                Start over
              </button>
            )}
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

          {status === 'checking' && <p className="chat-widget__state">Connecting…</p>}

          {status === 'off' && <p className="chat-widget__state">{OFFLINE_TEXT}</p>}

          {status === 'on' && (
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
                        <FormattedReply text={message.content} />
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
