import { useEffect, useState } from 'react';
import { getFeatures, setFeature } from '../lib/api.js';
import { currentUser, signIn, signInConfigured } from '../lib/auth.js';
import './FeatureFlags.css';

// The /features/ page ("Features"): turn features on and off, for the admins
// group. Everything comes from the employee API's /admin/features routes,
// which check the group themselves; this page only decides what to show. A
// change takes effect within seconds, for everyone, with no deploy.

// Who made a change, and how (infrastructure/aws/modules/employees/lambda/features.py).
// Workflow and Terraform changes already name themselves ("Chatbot on/off
// workflow", "Terraform"); a person gets their route added.
const VIA = { page: 'Features page', other: 'AWS console or CLI' };
const who = (change) => (VIA[change.source] ? `${change.changedBy} (${VIA[change.source]})` : change.changedBy);

const dateTime = (iso) =>
  iso ? new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '';

export default function FeatureFlags() {
  // loading | unconfigured | signedOut | forbidden | ready | error
  const [status, setStatus] = useState('loading');
  const [user, setUser] = useState(null);
  const [features, setFeatures] = useState([]);
  const [refreshing, setRefreshing] = useState(false);

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

  async function load() {
    if (!user) return;
    setRefreshing(true);
    const result = await getFeatures(user.id_token);
    setRefreshing(false);
    if (result.status === 'unauthorized') setStatus('signedOut');
    else if (result.status === 'forbidden') setStatus('forbidden');
    else if (result.status !== 'ok' || !Array.isArray(result.data?.features)) setStatus('error');
    else {
      setFeatures(result.data.features);
      setStatus('ready');
    }
  }

  useEffect(() => {
    load();
  }, [user]);

  const shell = (content) => (
    <div className="feature-flags">
      <h1 className="feature-flags__title">Features</h1>
      {content}
    </div>
  );

  if (status === 'loading') return <p className="feature-flags__muted">Loading…</p>;
  if (status === 'unconfigured') return shell(<p>Sign-in isn’t available right now.</p>);
  if (status === 'signedOut') {
    return shell(
      <>
        <p>Sign in with your A&amp;E RV Solutions employee account.</p>
        <button className="feature-flags__button" type="button" onClick={() => signIn()}>
          Sign in
        </button>
      </>,
    );
  }
  if (status === 'forbidden') {
    return shell(
      <>
        <p>Features is for admins.</p>
        <p>
          <a className="feature-flags__link" href="/employees/">
            Back to the Employees page
          </a>
        </p>
      </>,
    );
  }
  if (status === 'error') {
    return shell(
      <p className="feature-flags__error" role="alert">
        We couldn’t load the feature switches. Please try again shortly.
      </p>,
    );
  }

  return (
    <div className="feature-flags">
      <div className="feature-flags__bar">
        <h1 className="feature-flags__title">Features</h1>
        <button
          className="feature-flags__button feature-flags__button--quiet"
          type="button"
          onClick={load}
          disabled={refreshing}
        >
          {refreshing ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>
      <p className="feature-flags__lead">
        Turn features on and off for everyone. A change takes effect within seconds, with no deploy.
      </p>
      {features.length === 0 && <p className="feature-flags__muted">No feature switches are set up.</p>}
      {features.map((feature) => (
        <FeatureCard
          key={feature.name}
          feature={feature}
          token={user.id_token}
          onChanged={(updated) => setFeatures((all) => all.map((f) => (f.name === updated.name ? updated : f)))}
          onSignedOut={() => setStatus('signedOut')}
        />
      ))}
    </div>
  );
}

// One switch. Flipping it asks for confirmation first, and the card only
// shows the new state once the server has confirmed it.
function FeatureCard({ feature, token, onChanged, onSignedOut }) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const { name, label, description, offEffect, enabled } = feature;
  const known = enabled === true || enabled === false;
  const next = !enabled;

  async function change() {
    setBusy(true);
    setError('');
    const result = await setFeature(token, name, next);
    setBusy(false);
    setConfirming(false);
    if (result.status === 'ok' && result.data?.name === name) {
      onChanged(result.data);
      if (result.data.enabled !== next) {
        setError(`${label} is still ${result.data.enabled ? 'on' : 'off'}. Refresh and try again.`);
      }
    } else if (result.status === 'unauthorized') {
      onSignedOut();
    } else if (result.status === 'forbidden') {
      setError('Only admins can change this.');
    } else if (result.status === 'invalid') {
      setError(result.message);
    } else {
      setError('We couldn’t confirm the change. Refresh to see whether it was made.');
    }
  }

  return (
    <section className="feature-flags__card" aria-labelledby={`feature-${name}`}>
      <div className="feature-flags__head">
        <h2 className="feature-flags__name" id={`feature-${name}`}>
          {label}
        </h2>
        <span className="feature-flags__state" data-state={known ? (enabled ? 'on' : 'off') : 'unknown'}>
          {known ? (enabled ? 'On' : 'Off') : 'Unknown'}
        </span>
        <button
          type="button"
          role="switch"
          aria-checked={known ? enabled : false}
          aria-label={`${label} is ${known ? (enabled ? 'on' : 'off') : 'unknown'}. Turn ${next ? 'on' : 'off'}.`}
          className="feature-flags__switch"
          disabled={!known || busy || confirming}
          onClick={() => setConfirming(true)}
        >
          <span className="feature-flags__knob" aria-hidden="true" />
        </button>
      </div>

      <p>{description}</p>
      <p className="feature-flags__muted">When off: {offEffect}</p>

      {feature.error && (
        <p className="feature-flags__error" role="alert">
          {feature.error} It’s treated as off until it can be read.
        </p>
      )}

      {confirming && (
        <div className="feature-flags__confirm" role="group" aria-label={`Confirm turning ${label} ${next ? 'on' : 'off'}`}>
          <p>
            <strong>
              Turn {label} {next ? 'on' : 'off'} for everyone?
            </strong>{' '}
            {next ? 'It’s available again within seconds.' : offEffect}
          </p>
          <div className="feature-flags__actions">
            <button
              type="button"
              className={`feature-flags__button${next ? '' : ' feature-flags__button--danger'}`}
              onClick={change}
              disabled={busy}
            >
              {busy ? 'Saving…' : `Turn ${next ? 'on' : 'off'}`}
            </button>
            <button
              type="button"
              className="feature-flags__button feature-flags__button--quiet"
              onClick={() => setConfirming(false)}
              disabled={busy}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {error && (
        <p className="feature-flags__error" role="alert">
          {error}
        </p>
      )}

      {feature.updatedAt && (
        <p className="feature-flags__muted">
          Last changed {dateTime(feature.updatedAt)} by {who(feature)}.
        </p>
      )}

      {feature.history?.length > 0 && (
        <details className="feature-flags__history">
          <summary>Recent changes ({feature.history.length})</summary>
          <ul>
            {feature.history.map((change) => (
              <li key={change.at}>
                <span className="feature-flags__when">{dateTime(change.at)}</span>{' '}
                <strong>{change.enabled ? 'On' : 'Off'}</strong> · {who(change)}
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}
