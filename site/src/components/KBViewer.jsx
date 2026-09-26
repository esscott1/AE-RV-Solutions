import { useEffect, useState } from 'react';
import { strToU8, zipSync } from 'fflate';
import { signIn } from '../lib/auth.js';
import { getKnowledgeDocuments, reindexKnowledge, removeKnowledge } from '../lib/api.js';
import { useEmployee } from '../lib/useEmployee.js';
import { Gate, MarkdownView, formatDate, indexingText } from './KnowledgeForm.jsx';

// /kb-viewer/: everything Eddie knows (approved/ in the documents bucket),
// for any employee to read and download. Admins can remove an entry or
// re-index.

const FOLDERS = { capabilities: 'Capabilities', faq: 'FAQs', notes: 'Notes' };

function save(filename, type, data) {
  const url = URL.createObjectURL(new Blob([data], { type }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

const fileName = (doc) => doc.key.split('/').pop();

function downloadAll(docs) {
  const files = Object.fromEntries(docs.map((d) => [d.key.replace(/^approved\//, ''), strToU8(d.content)]));
  const today = new Date().toISOString().slice(0, 10);
  save(`ae-rv-knowledge-${today}.zip`, 'application/zip', zipSync(files));
}

export default function KBViewer() {
  const employee = useEmployee();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [open, setOpen] = useState(() => new Set());
  const [busy, setBusy] = useState('');

  const token = employee.user?.id_token;
  const load = () =>
    token &&
    getKnowledgeDocuments(token).then((r) => {
      if (r.status === 'ok') setData(r.data);
      else setError('Couldn’t load the knowledge base.');
    });

  useEffect(() => {
    load();
  }, [token]);

  const toggle = (id) =>
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const remove = async (doc) => {
    if (!window.confirm(`Remove “${doc.title}” from Eddie’s knowledge? It can be restored for a year from the S3 bucket's versions.`)) return;
    setBusy(doc.id);
    const result = await removeKnowledge(token, doc.id);
    setBusy('');
    setNotice(result.status === 'ok' ? `Removed “${doc.title}”. ${indexingText(result.data.indexing)}` : 'Couldn’t remove it.');
    load();
  };

  const reindex = async () => {
    setBusy('reindex');
    const result = await reindexKnowledge(token);
    setBusy('');
    setNotice(result.status === 'ok' ? indexingText(result.data.indexing) : 'Couldn’t start indexing.');
    load();
  };

  const groups = {};
  for (const doc of data?.documents ?? []) (groups[doc.folder] ??= []).push(doc);

  return (
    <Gate employee={employee} title="KBViewer" onSignIn={() => signIn()}>
      <div className="knowledge">
        <div className="knowledge__bar">
          <h1 className="knowledge__title">KBViewer</h1>
          <div className="knowledge__actions">
            <button
              type="button"
              className="knowledge__button knowledge__button--quiet"
              disabled={!data?.documents.length}
              onClick={() => downloadAll(data.documents)}
            >
              Download all (.zip)
            </button>
            {employee.isAdmin && (
              <button
                type="button"
                className="knowledge__button knowledge__button--quiet"
                disabled={busy === 'reindex'}
                onClick={reindex}
              >
                Re-index
              </button>
            )}
          </div>
        </div>
        <p className="knowledge__lead">Everything Eddie uses to answer customers. Add to it on Add Knowledge.</p>
        {data && <p className="knowledge__muted">{indexingText(data.indexing)}</p>}
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
        {!data && !error && <p className="knowledge__muted">Loading…</p>}
        {data?.documents.length === 0 && <p className="knowledge__muted">Eddie has no knowledge yet.</p>}

        {Object.entries(groups).map(([folder, docs]) => (
          <section key={folder} className="knowledge__section" aria-labelledby={`folder-${folder}`}>
            <h2 className="knowledge__subtitle" id={`folder-${folder}`}>
              {FOLDERS[folder] ?? folder} <span className="knowledge__muted">({docs.length})</span>
            </h2>
            <ul className="knowledge__list">
              {docs.map((doc) => (
                <li key={doc.id} className="knowledge__card">
                  <div className="knowledge__card-head">
                    <button
                      type="button"
                      className="knowledge__expand"
                      aria-expanded={open.has(doc.id)}
                      onClick={() => toggle(doc.id)}
                    >
                      <span aria-hidden="true">{open.has(doc.id) ? '▾' : '▸'}</span> <strong>{doc.title}</strong>
                    </button>
                    <span className="knowledge__muted" title={doc.authorSub ? `Employee ID ${doc.authorSub}` : undefined}>
                      {doc.author ? `by ${doc.author} · ` : ''}
                      {doc.origin === 'chat' ? 'drafted with Herman · ' : ''}updated {formatDate(doc.updatedAt)}
                    </span>
                    <span className="knowledge__actions">
                      <button
                        type="button"
                        className="knowledge__button knowledge__button--quiet"
                        onClick={() => save(fileName(doc), 'text/markdown;charset=utf-8', doc.content)}
                      >
                        Download .md
                      </button>
                      {employee.isAdmin && (
                        <button
                          type="button"
                          className="knowledge__button knowledge__button--danger"
                          disabled={busy === doc.id}
                          onClick={() => remove(doc)}
                        >
                          Remove
                        </button>
                      )}
                    </span>
                  </div>
                  {open.has(doc.id) && <MarkdownView markdown={doc.content} />}
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </Gate>
  );
}
