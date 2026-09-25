import { useEffect, useState } from 'react';
import { signIn } from '../lib/auth.js';
import { approveKnowledge, getPendingKnowledge, rejectKnowledge } from '../lib/api.js';
import { TYPES, validate } from '../lib/knowledge.js';
import { useEmployee } from '../lib/useEmployee.js';
import { Gate, KnowledgeForm, MarkdownView, Preview, formatDate, indexingText } from './KnowledgeForm.jsx';

// /kb-validation/: admins (the Cognito admins group) review submitted
// knowledge. Approving publishes it to approved/ and starts indexing;
// rejecting sends the reason back to the employee.
export default function KBValidation() {
  const employee = useEmployee();
  const [entries, setEntries] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const token = employee.user?.id_token;
  const load = () =>
    token &&
    getPendingKnowledge(token).then((r) => {
      if (r.status === 'ok') setEntries(r.data.entries);
      else setError(r.status === 'forbidden' ? 'KBValidation is for admins.' : 'Couldn’t load the queue.');
    });

  useEffect(() => {
    if (employee.isAdmin) load();
  }, [token, employee.isAdmin]);

  const done = (text) => {
    setNotice(text);
    load();
  };

  return (
    <Gate employee={employee} title="KBValidation" adminOnly onSignIn={() => signIn()}>
      <div className="knowledge">
        <h1 className="knowledge__title">KBValidation</h1>
        <p className="knowledge__lead">
          Knowledge employees have submitted. Approve it to add it to Eddie’s knowledge, edit it first if needed, or
          reject it with a reason the employee will see.
        </p>
        {notice && (
          <p className="knowledge__message knowledge__message--ok" role="status">
            {notice}
          </p>
        )}
        {error && (
          <p className="knowledge__message knowledge__message--error" role="alert">
            {error}
          </p>
        )}
        {entries === null && !error && <p className="knowledge__muted">Loading…</p>}
        {entries?.length === 0 && <p className="knowledge__muted">Nothing waiting for review.</p>}
        {entries?.map((entry) => (
          <PendingEntry key={entry.id} entry={entry} token={token} onDone={done} />
        ))}
      </div>
    </Gate>
  );
}

function PendingEntry({ entry, token, onDone }) {
  const [editing, setEditing] = useState(false);
  const [fields, setFields] = useState(entry.fields);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const act = async (call, successText) => {
    setBusy(true);
    setError('');
    const result = await call();
    setBusy(false);
    if (result.status === 'ok') onDone(successText(result.data));
    else setError(result.status === 'invalid' ? result.message : 'That didn’t work. Please try again.');
  };

  const approve = () => {
    if (editing) {
      const problem = validate(entry.type, fields);
      if (problem) {
        setError(problem);
        return;
      }
    }
    act(
      () => approveKnowledge(token, entry.id, editing ? fields : undefined),
      (data) => `Approved “${fields.title}”. ${indexingText(data.indexing)}`,
    );
  };

  return (
    <article className="knowledge__card">
      <header className="knowledge__card-head">
        <span className="knowledge__badge">{TYPES[entry.type]?.label ?? entry.type}</span>
        <strong>{entry.fields.title}</strong>
        <span className="knowledge__muted">
          by {entry.author?.email} · {formatDate(entry.submittedAt)}
        </span>
      </header>

      {editing ? (
        <>
          <KnowledgeForm type={entry.type} fields={fields} onChange={setFields} disabled={busy} />
          <Preview type={entry.type} fields={fields} />
        </>
      ) : (
        <MarkdownView markdown={entry.markdown} />
      )}

      {rejecting && (
        <div className="knowledge__field">
          <label className="knowledge__label" htmlFor={`reason-${entry.id}`}>
            Reason for rejecting (the employee sees this)
          </label>
          <textarea
            id={`reason-${entry.id}`}
            className="knowledge__textarea"
            rows={2}
            maxLength={500}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
      )}

      {error && (
        <p className="knowledge__message knowledge__message--error" role="alert">
          {error}
        </p>
      )}

      <div className="knowledge__actions">
        {rejecting ? (
          <>
            <button
              type="button"
              className="knowledge__button knowledge__button--danger"
              disabled={busy || !reason.trim()}
              onClick={() => act(() => rejectKnowledge(token, entry.id, reason), () => `Rejected “${entry.fields.title}”.`)}
            >
              Confirm reject
            </button>
            <button type="button" className="knowledge__button knowledge__button--quiet" onClick={() => setRejecting(false)}>
              Cancel
            </button>
          </>
        ) : (
          <>
            <button type="button" className="knowledge__button" disabled={busy} onClick={approve}>
              {busy ? 'Working…' : editing ? 'Approve with my edits' : 'Approve'}
            </button>
            <button
              type="button"
              className="knowledge__button knowledge__button--quiet"
              disabled={busy}
              onClick={() => {
                setEditing(!editing);
                setFields(entry.fields);
              }}
            >
              {editing ? 'Cancel edits' : 'Edit'}
            </button>
            <button
              type="button"
              className="knowledge__button knowledge__button--quiet"
              disabled={busy}
              onClick={() => setRejecting(true)}
            >
              Reject
            </button>
          </>
        )}
      </div>
    </article>
  );
}
