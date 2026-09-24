import { Fragment, useEffect, useState } from 'react';
import { currentUser, signIn, signInConfigured } from '../lib/auth.js';
import { getAdminConversations, getAdminUsage } from '../lib/api.js';
import './AdminPanel.css';

// The /admin/ page: Eddie's usage and chat conversations, for the admins
// group. Everything comes from the employee API's admin routes, which check
// the group themselves; this page only decides what to show.

const RANGES = [7, 30];
const SAFETY_ROUTES = ['safety_referral', 'emergency'];
const ROUTE_LABELS = {
  answer: 'Answer',
  safety_referral: 'Safety referral',
  emergency: 'Emergency',
  decline: 'Declined',
  unavailable: 'Unavailable',
  invalid: 'Invalid',
  offline: 'Offline',
};

const count = new Intl.NumberFormat();
const money = (value) =>
  new Intl.NumberFormat(undefined, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: value > 0 && value < 0.01 ? 4 : 2,
    maximumFractionDigits: value > 0 && value < 0.01 ? 4 : 2,
  }).format(value);
const dateTime = (iso) =>
  iso ? new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '';
const shortDay = (ymd) =>
  new Date(`${ymd}T00:00:00Z`).toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  });

function routeSummary(routes) {
  return Object.entries(routes)
    .sort((a, b) => b[1] - a[1])
    .map(([route, n]) => `${ROUTE_LABELS[route] ?? route}${n > 1 ? ` ×${n}` : ''}`)
    .join(', ');
}

export default function AdminPanel() {
  // loading | unconfigured | signedOut | forbidden | ready | error
  const [status, setStatus] = useState('loading');
  const [user, setUser] = useState(null);
  const [days, setDays] = useState(7);
  const [usage, setUsage] = useState(null);
  const [conversations, setConversations] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!signInConfigured) {
      setStatus('unconfigured');
      return;
    }
    currentUser()
      .then((signedIn) => {
        if (signedIn) setUser(signedIn);
        else setStatus('signedOut');
      })
      .catch(() => setStatus('signedOut'));
  }, []);

  useEffect(() => {
    if (!user) return;
    let cancelled = false;
    setBusy(true);
    Promise.all([getAdminUsage(user.id_token, days), getAdminConversations(user.id_token, days)]).then(
      ([u, c]) => {
        if (cancelled) return;
        setBusy(false);
        const worst = [u.status, c.status].find((s) => s !== 'ok');
        if (worst === 'unauthorized') setStatus('signedOut');
        else if (worst === 'forbidden') setStatus('forbidden');
        else if (worst) setStatus('error');
        else {
          setUsage(u.data);
          setConversations(c.data);
          setStatus('ready');
        }
      },
    );
    return () => {
      cancelled = true;
    };
  }, [user, days]);

  if (status === 'loading') return <p className="admin-panel__muted">Loading…</p>;

  if (status === 'unconfigured') {
    return (
      <div className="admin-panel">
        <h1 className="admin-panel__title">Admin</h1>
        <p>Sign-in isn’t available right now.</p>
      </div>
    );
  }

  if (status === 'signedOut') {
    return (
      <div className="admin-panel">
        <h1 className="admin-panel__title">Admin</h1>
        <p>Sign in with your A&amp;E RV Solutions employee account.</p>
        <button className="admin-panel__button" type="button" onClick={() => signIn()}>
          Sign in
        </button>
      </div>
    );
  }

  if (status === 'forbidden') {
    return (
      <div className="admin-panel">
        <h1 className="admin-panel__title">Admin</h1>
        <p>This page is for admins.</p>
        <p>
          <a className="admin-panel__link" href="/employees/">
            Back to the Employees page
          </a>
        </p>
      </div>
    );
  }

  if (status === 'error') {
    return (
      <div className="admin-panel">
        <h1 className="admin-panel__title">Admin</h1>
        <p className="admin-panel__error" role="alert">
          We couldn’t load the admin data. Please try again shortly.
        </p>
      </div>
    );
  }

  return (
    <div className="admin-panel">
      <div className="admin-panel__bar">
        <h1 className="admin-panel__title">Admin</h1>
        <div className="admin-panel__range" role="group" aria-label="Date range">
          {RANGES.map((n) => (
            <button
              key={n}
              type="button"
              className="admin-panel__range-button"
              aria-pressed={days === n}
              disabled={busy}
              onClick={() => setDays(n)}
            >
              Last {n} days
            </button>
          ))}
        </div>
      </div>
      <p className="admin-panel__muted">
        Days are UTC. Costs are estimates of Bedrock model cost at{' '}
        {money(usage.prices.inputPerMillion)} / {money(usage.prices.outputPerMillion)} per million
        input / output tokens.
        {busy && ' Updating…'}
      </p>
      <Usage usage={usage} />
      <Conversations data={conversations} />
    </div>
  );
}

function Usage({ usage }) {
  const { totals } = usage;
  const safety = SAFETY_ROUTES.reduce((n, route) => n + (totals.routes[route] ?? 0), 0);
  const tiles = [
    ['Conversations', count.format(totals.conversations)],
    ['Exchanges', count.format(totals.exchanges)],
    ['Safety referrals', count.format(safety)],
    ['Tokens (in / out)', `${count.format(totals.tokensIn)} / ${count.format(totals.tokensOut)}`],
    ['Estimated cost', money(totals.cost)],
  ];

  return (
    <section className="admin-panel__section" aria-labelledby="admin-usage">
      <h2 className="admin-panel__subtitle" id="admin-usage">
        AI usage
      </h2>
      <dl className="admin-panel__tiles">
        {tiles.map(([label, value]) => (
          <div className="admin-panel__tile" key={label}>
            <dt className="admin-panel__tile-label">{label}</dt>
            <dd className="admin-panel__tile-value">{value}</dd>
          </div>
        ))}
      </dl>
      <DailyChart rows={usage.days} />
      <div className="admin-panel__table-wrap">
        <table className="admin-panel__table">
          <caption className="admin-panel__sr-only">Usage per day</caption>
          <thead>
            <tr>
              <th scope="col">Day</th>
              <th scope="col">Chat requests</th>
              <th scope="col">Conversations</th>
              <th scope="col">Routes</th>
              <th scope="col">Tokens (in / out)</th>
              <th scope="col">Est. cost</th>
            </tr>
          </thead>
          <tbody>
            {[...usage.days].reverse().map((row) => (
              <tr key={row.date}>
                <th scope="row">{shortDay(row.date)}</th>
                <td>
                  {count.format(row.requests)}
                  {row.quota ? ` / ${row.quota}` : ''}
                </td>
                <td>{count.format(row.conversations)}</td>
                <td>{routeSummary(row.routes) || '—'}</td>
                <td>
                  {count.format(row.tokensIn)} / {count.format(row.tokensOut)}
                </td>
                <td>{money(row.cost)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

// Chat requests per day against the daily limit. One series, so no legend:
// the heading names it. SVG so each bar's height is an attribute (no inline
// styles). The dashed line is the limit; hovering or focusing a day shows its
// numbers above the chart, and the table below lists them all.
const PLOT_H = 120;
const SLOT_W = 24;
const BAR_W = 16;
const RADIUS = 4;

// A bar with rounded top corners, square at the baseline.
function barPath(x, height) {
  const r = Math.min(RADIUS, height, BAR_W / 2);
  const top = PLOT_H - height;
  return [
    `M${x},${PLOT_H}`,
    `V${top + r}`,
    `Q${x},${top} ${x + r},${top}`,
    `H${x + BAR_W - r}`,
    `Q${x + BAR_W},${top} ${x + BAR_W},${top + r}`,
    `V${PLOT_H}`,
    'Z',
  ].join(' ');
}

function DailyChart({ rows }) {
  const limit = Math.max(...rows.map((r) => r.quota ?? 0), 1);
  const [active, setActive] = useState(null);
  const shown = active ?? rows.length - 1;
  const current = rows[shown];
  const width = rows.length * SLOT_W;

  return (
    <figure className="admin-panel__chart">
      <figcaption className="admin-panel__chart-title">
        Chat requests per day <span className="admin-panel__muted">(limit {limit})</span>
      </figcaption>
      <p className="admin-panel__chart-readout" aria-live="polite">
        {shortDay(current.date)}: {count.format(current.requests)} request
        {current.requests === 1 ? '' : 's'}, {count.format(current.conversations)} conversation
        {current.conversations === 1 ? '' : 's'}, {money(current.cost)}
      </p>
      <svg
        className="admin-panel__plot"
        viewBox={`0 -4 ${width} ${PLOT_H + 4}`}
        preserveAspectRatio="none"
        onMouseLeave={() => setActive(null)}
      >
        <line className="admin-panel__limit" x1="0" x2={width} y1="0" y2="0" />
        <line className="admin-panel__baseline" x1="0" x2={width} y1={PLOT_H} y2={PLOT_H} />
        {rows.map((row, i) => {
          const height = Math.min(row.requests / limit, 1) * PLOT_H;
          const x = i * SLOT_W + (SLOT_W - BAR_W) / 2;
          return (
            <g
              key={row.date}
              className="admin-panel__day"
              data-active={i === shown}
              tabIndex={0}
              role="img"
              aria-label={`${shortDay(row.date)}: ${row.requests} of ${row.quota ?? limit} requests`}
              onMouseEnter={() => setActive(i)}
              onFocus={() => setActive(i)}
            >
              <rect className="admin-panel__hit" x={i * SLOT_W} y="0" width={SLOT_W} height={PLOT_H} />
              {height > 0 && <path className="admin-panel__bar" d={barPath(x, height)} />}
            </g>
          );
        })}
      </svg>
      <div className="admin-panel__axis" aria-hidden="true">
        <span>{shortDay(rows[0].date)}</span>
        <span>{shortDay(rows[rows.length - 1].date)}</span>
      </div>
    </figure>
  );
}

function Conversations({ data }) {
  const [open, setOpen] = useState(() => new Set());
  const toggle = (id) =>
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  return (
    <section className="admin-panel__section" aria-labelledby="admin-conversations">
      <div className="admin-panel__bar">
        <h2 className="admin-panel__subtitle" id="admin-conversations">
          Conversations
        </h2>
        <div className="admin-panel__downloads">
          <button
            type="button"
            className="admin-panel__button admin-panel__button--quiet"
            disabled={data.conversations.length === 0}
            onClick={() => downloadCsv(data)}
          >
            Download CSV
          </button>
          <button
            type="button"
            className="admin-panel__button admin-panel__button--quiet"
            disabled={data.conversations.length === 0}
            onClick={() => downloadJson(data)}
          >
            Download JSON
          </button>
        </div>
      </div>
      <p className="admin-panel__muted">
        Transcripts are kept for 30 days. Downloads hold visitors’ messages: keep them private.
      </p>

      {data.conversations.length === 0 ? (
        <p>No conversations in this range.</p>
      ) : (
        <div className="admin-panel__table-wrap">
          <table className="admin-panel__table">
            <caption className="admin-panel__sr-only">Conversations, newest first</caption>
            <thead>
              <tr>
                <th scope="col">Started</th>
                <th scope="col">Exchanges</th>
                <th scope="col">Routes</th>
                <th scope="col">Tokens (in / out)</th>
                <th scope="col">Est. cost</th>
              </tr>
            </thead>
            <tbody>
              {data.conversations.map((c) => {
                const expanded = open.has(c.id);
                const flagged = SAFETY_ROUTES.some((route) => c.routes[route]);
                return (
                  <Fragment key={c.id}>
                    <tr>
                      <th scope="row">
                        <button
                          type="button"
                          className="admin-panel__expand"
                          aria-expanded={expanded}
                          onClick={() => toggle(c.id)}
                        >
                          <span aria-hidden="true">{expanded ? '▾' : '▸'}</span> {dateTime(c.start)}
                        </button>
                      </th>
                      <td>{c.exchanges.length}</td>
                      <td>
                        {flagged && (
                          <span className="admin-panel__flag">
                            <span aria-hidden="true">⚠</span> Safety{' '}
                          </span>
                        )}
                        {routeSummary(c.routes)}
                      </td>
                      <td>
                        {count.format(c.tokensIn)} / {count.format(c.tokensOut)}
                      </td>
                      <td>{money(c.cost)}</td>
                    </tr>
                    {expanded && (
                      <tr className="admin-panel__detail-row">
                        <td colSpan={5}>
                          <ol className="admin-panel__exchanges">
                            {c.exchanges.map((e, i) => (
                              <li key={i} className="admin-panel__exchange">
                                <p className="admin-panel__exchange-meta">
                                  {dateTime(e.time)} · {ROUTE_LABELS[e.route] ?? e.route}
                                  {e.source ? ` (${e.source.replace('_', ' ')})` : ''} ·{' '}
                                  {count.format(e.tokensIn)} / {count.format(e.tokensOut)} tokens ·{' '}
                                  {money(e.cost)}
                                </p>
                                <p className="admin-panel__said">
                                  <strong>Visitor:</strong> {e.message}
                                </p>
                                <p className="admin-panel__said">
                                  <strong>Eddie:</strong> {e.reply}
                                </p>
                              </li>
                            ))}
                          </ol>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

// --- Downloads (built in the browser from the data already loaded) --------------

function save(filename, type, text) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

const fileName = (data, ext) => `ae-rv-conversations-${data.from}-to-${data.to}.${ext}`;

// Quoted and escaped; text that Excel would run as a formula (starting with
// = + - @ or a tab/return) gets a leading apostrophe so it opens as text.
function csvCell(value) {
  let text = value == null ? '' : String(value);
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return `"${text.replace(/"/g, '""')}"`;
}

function downloadCsv(data) {
  const header = [
    'Conversation ID',
    'Conversation start (UTC)',
    'Time (UTC)',
    'Route',
    'Source',
    'Visitor message',
    "Eddie's reply",
    'Input tokens',
    'Output tokens',
    'Estimated cost (USD)',
  ];
  const rows = [...data.conversations]
    .sort((a, b) => (a.start ?? '').localeCompare(b.start ?? ''))
    .flatMap((c) =>
      c.exchanges.map((e) => [
        c.id,
        c.start,
        e.time,
        e.route,
        e.source ?? '',
        e.message,
        e.reply,
        e.tokensIn,
        e.tokensOut,
        e.cost,
      ]),
    );
  const text = [header, ...rows].map((row) => row.map(csvCell).join(',')).join('\r\n');
  // The byte-order mark makes Excel read the file as UTF-8.
  save(fileName(data, 'csv'), 'text/csv;charset=utf-8', `﻿${text}\r\n`);
}

function downloadJson(data) {
  save(fileName(data, 'json'), 'application/json', JSON.stringify(data, null, 2));
}
