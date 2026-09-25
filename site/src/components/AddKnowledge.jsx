import { useEffect, useState } from 'react';
import { signIn } from '../lib/auth.js';
import { getMyKnowledge, submitKnowledge } from '../lib/api.js';
import { TYPES, WRITING_TIPS, emptyFields, validate } from '../lib/knowledge.js';
import { useEmployee } from '../lib/useEmployee.js';
import { Gate, KnowledgeForm, Preview, formatDate } from './KnowledgeForm.jsx';

// /add-knowledge/: any employee submits knowledge for an admin to review on
// KBValidation. Nothing reaches Eddie until it's approved.
export default function AddKnowledge() {
  const employee = useEmployee();
  const [type, setType] = useState(null);
  const [fields, setFields] = useState(null);
  const [message, setMessage] = useState(null);
  const [busy, setBusy] = useState(false);
  const [mine, setMine] = useState(null);

  const token = employee.user?.id_token;
  const loadMine = () => token && getMyKnowledge(token).then((r) => setMine(r.status === 'ok' ? r.data.entries : []));

  useEffect(() => {
    loadMine();
  }, [token]);

  const pick = (next) => {
    setType(next);
    setFields(emptyFields(next));
    setMessage(null);
  };

  const submit = async (event) => {
    event.preventDefault();
    const problem = validate(type, fields);
    if (problem) {
      setMessage({ kind: 'error', text: problem });
      return;
    }
    setBusy(true);
    const result = await submitKnowledge(token, type, fields);
    setBusy(false);
    if (result.status === 'ok') {
      setMessage({ kind: 'ok', text: 'Submitted. An admin will review it on KBValidation before Eddie uses it.' });
      setType(null);
      setFields(null);
      loadMine();
    } else {
      setMessage({
        kind: 'error',
        text: result.status === 'invalid' ? result.message : 'Couldn’t submit. Please try again, or sign in again.',
      });
    }
  };

  return (
    <Gate employee={employee} title="Add Knowledge" onSignIn={() => signIn()}>
      <div className="knowledge">
        <h1 className="knowledge__title">Add Knowledge</h1>
        <p className="knowledge__lead">
          Teach Eddie something from your experience. An admin reviews every entry before Eddie uses it.
        </p>

        <fieldset className="knowledge__types">
          <legend className="knowledge__label">What kind of knowledge is it?</legend>
          {Object.entries(TYPES).map(([key, info]) => (
            <label key={key} className="knowledge__type" data-selected={type === key}>
              <input
                type="radio"
                name="knowledge-type"
                className="knowledge__sr-only"
                checked={type === key}
                onChange={() => pick(key)}
              />
              <span className="knowledge__type-name">{info.label}</span>
              <span className="knowledge__type-card">{info.card}</span>
              <span className="knowledge__type-eddie">Eddie: {info.eddie}</span>
            </label>
          ))}
        </fieldset>
        <p className="knowledge__hint">
          Not sure? If a customer would ask “how do I…”, it’s a Capability. A quick question with a quick answer is
          an FAQ. Anything else is a Note.
        </p>

        {type && (
          <form className="knowledge__compose" onSubmit={submit}>
            <details className="knowledge__tips">
              <summary>Writing tips</summary>
              <ul>
                {WRITING_TIPS.map((tip) => (
                  <li key={tip}>{tip}</li>
                ))}
              </ul>
            </details>
            <KnowledgeForm type={type} fields={fields} onChange={setFields} disabled={busy} />
            <Preview type={type} fields={fields} />
            <button type="submit" className="knowledge__button" disabled={busy}>
              {busy ? 'Submitting…' : 'Submit for review'}
            </button>
          </form>
        )}
        {message && (
          <p className={`knowledge__message knowledge__message--${message.kind}`} role="status">
            {message.text}
          </p>
        )}

        <section className="knowledge__section" aria-labelledby="my-submissions">
          <h2 className="knowledge__subtitle" id="my-submissions">
            My submissions
          </h2>
          {mine === null && <p className="knowledge__muted">Loading…</p>}
          {mine?.length === 0 && <p className="knowledge__muted">Nothing submitted yet.</p>}
          {mine?.length > 0 && (
            <ul className="knowledge__list">
              {mine.map((entry) => (
                <li key={entry.id} className="knowledge__row">
                  <span className="knowledge__badge" data-status={entry.status}>
                    {entry.status}
                  </span>
                  <span>
                    <strong>{entry.title}</strong>{' '}
                    <span className="knowledge__muted">
                      · {TYPES[entry.type]?.label ?? entry.type} · submitted {formatDate(entry.submittedAt)}
                    </span>
                    {entry.reason && <span className="knowledge__reason">Reason: {entry.reason}</span>}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </Gate>
  );
}
