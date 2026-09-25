import { useId } from 'react';
import { CAPABILITY_SECTIONS, LIMITS, TYPES, buildMarkdown, markdownBlocks } from '../lib/knowledge.js';
import './Knowledge.css';

// Pieces shared by the Add Knowledge, KBValidation and KBViewer islands.
// Styles: Knowledge.css (.knowledge__ classes).

// The guided sections for one kind of knowledge. `fields` and `onChange`
// hold the whole entry, so the same form serves submitting and an admin's
// edit before approving.
export function KnowledgeForm({ type, fields, onChange, disabled = false }) {
  const id = useId();
  const set = (patch) => onChange({ ...fields, ...patch });
  const info = TYPES[type];

  return (
    <div className="knowledge__form">
      <Field id={`${id}-title`} label={info.titleLabel} hint={info.titleHint}>
        <input
          id={`${id}-title`}
          className="knowledge__input"
          maxLength={LIMITS.title}
          value={fields.title}
          disabled={disabled}
          onChange={(e) => set({ title: e.target.value })}
        />
      </Field>

      {type === 'capability' &&
        CAPABILITY_SECTIONS.map((s) => (
          <Field key={s.key} id={`${id}-${s.key}`} label={s.label} hint={s.hint}>
            <TextArea
              id={`${id}-${s.key}`}
              value={fields[s.key]}
              disabled={disabled}
              onChange={(value) => set({ [s.key]: value })}
            />
          </Field>
        ))}

      {type === 'faq' && (
        <Repeating
          items={fields.pairs}
          max={LIMITS.pairs}
          noun="question"
          disabled={disabled}
          blank={{ question: '', answer: '' }}
          onChange={(pairs) => set({ pairs })}
          render={(pair, i, update) => (
            <>
              <Field id={`${id}-q${i}`} label={`Question ${i + 1}`} hint="Phrase it the way a customer would ask.">
                <input
                  id={`${id}-q${i}`}
                  className="knowledge__input"
                  maxLength={LIMITS.question}
                  value={pair.question}
                  disabled={disabled}
                  onChange={(e) => update({ question: e.target.value })}
                />
              </Field>
              <Field id={`${id}-a${i}`} label="Answer" hint="Short enough to stand on its own (about 200 words or less).">
                <TextArea id={`${id}-a${i}`} value={pair.answer} disabled={disabled} onChange={(answer) => update({ answer })} />
              </Field>
            </>
          )}
        />
      )}

      {type === 'note' && (
        <Repeating
          items={fields.sections}
          max={LIMITS.sections}
          noun="section"
          disabled={disabled}
          blank={{ heading: '', body: '' }}
          onChange={(sections) => set({ sections })}
          render={(section, i, update) => (
            <>
              <Field id={`${id}-h${i}`} label={`Section ${i + 1} heading`} hint="One topic per section.">
                <input
                  id={`${id}-h${i}`}
                  className="knowledge__input"
                  maxLength={LIMITS.heading}
                  value={section.heading}
                  disabled={disabled}
                  onChange={(e) => update({ heading: e.target.value })}
                />
              </Field>
              <Field id={`${id}-b${i}`} label="Text">
                <TextArea id={`${id}-b${i}`} value={section.body} disabled={disabled} onChange={(b) => update({ body: b })} />
              </Field>
            </>
          )}
        />
      )}
    </div>
  );
}

function Field({ id, label, hint, children }) {
  return (
    <div className="knowledge__field">
      <label className="knowledge__label" htmlFor={id}>
        {label}
      </label>
      {hint && <p className="knowledge__hint">{hint}</p>}
      {children}
    </div>
  );
}

function TextArea({ id, value, onChange, disabled }) {
  return (
    <>
      <textarea
        id={id}
        className="knowledge__textarea"
        rows={4}
        maxLength={LIMITS.text}
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
      />
      {value.length > LIMITS.text * 0.8 && (
        <p className="knowledge__hint">
          {value.length} / {LIMITS.text}
        </p>
      )}
    </>
  );
}

function Repeating({ items, max, noun, blank, onChange, render, disabled }) {
  const update = (i) => (patch) => onChange(items.map((item, j) => (j === i ? { ...item, ...patch } : item)));
  return (
    <div className="knowledge__repeating">
      {items.map((item, i) => (
        <fieldset className="knowledge__group" key={i}>
          {render(item, i, update(i))}
          {items.length > 1 && !disabled && (
            <button
              type="button"
              className="knowledge__button knowledge__button--quiet"
              onClick={() => onChange(items.filter((_, j) => j !== i))}
            >
              Remove this {noun}
            </button>
          )}
        </fieldset>
      ))}
      {items.length < max && !disabled && (
        <button type="button" className="knowledge__button knowledge__button--quiet" onClick={() => onChange([...items, blank])}>
          + Add another {noun}
        </button>
      )}
    </div>
  );
}

// A Markdown document as formatted text (headings, paragraphs, lists).
export function MarkdownView({ markdown }) {
  return (
    <div className="knowledge__doc">
      {markdownBlocks(markdown).map((block, i) => {
        if (block.kind === 'ul') {
          return (
            <ul key={i}>
              {block.items.map((item, j) => (
                <li key={j}>{item}</li>
              ))}
            </ul>
          );
        }
        const Tag = block.kind === 'p' ? 'p' : block.kind;
        return <Tag key={i}>{block.text}</Tag>;
      })}
    </div>
  );
}

// What Bedrock will index for these fields.
export function Preview({ type, fields }) {
  return (
    <section className="knowledge__preview" aria-label="Preview">
      <p className="knowledge__preview-title">Preview: what Eddie will learn</p>
      <MarkdownView markdown={buildMarkdown(type, fields)} />
    </section>
  );
}

// Sign-in states every knowledge page shares.
export function Gate({ employee, title, adminOnly = false, onSignIn, children }) {
  if (employee.status === 'loading') return <p className="knowledge__muted">Loading…</p>;
  const shell = (content) => (
    <div className="knowledge">
      <h1 className="knowledge__title">{title}</h1>
      {content}
    </div>
  );
  if (employee.status === 'unconfigured') return shell(<p>Sign-in isn’t available right now.</p>);
  if (employee.status === 'signedOut') {
    return shell(
      <>
        <p>Sign in with your A&amp;E RV Solutions employee account.</p>
        <button type="button" className="knowledge__button" onClick={onSignIn}>
          Sign in
        </button>
      </>,
    );
  }
  if (adminOnly && !employee.isAdmin) return shell(<p>{title} is for admins.</p>);
  return children;
}

export const formatDate = (iso) =>
  iso ? new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '';

export function indexingText(indexing) {
  if (!indexing) return 'Not indexed yet.';
  const labels = {
    STARTING: 'Indexing is starting',
    IN_PROGRESS: 'Indexing is in progress',
    COMPLETE: 'Last indexed',
    FAILED: 'Last indexing FAILED',
    STOPPED: 'Last indexing was stopped',
    BUSY: 'Indexing is already running',
  };
  const when = indexing.updatedAt ? ` ${formatDate(indexing.updatedAt)}` : '';
  return `${labels[indexing.status] ?? indexing.status}${when}.`;
}
