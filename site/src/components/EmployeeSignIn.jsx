import { useEffect, useId, useState } from 'react';
import QRCode from 'qrcode';
import {
  addPasskeyUrl,
  completeSignIn,
  currentUser,
  signIn,
  signInConfigured,
} from '../lib/auth.js';
import {
  finishAuthenticatorSetup,
  getAccountSecurity,
  getEmployeeMe,
  removePasskey,
  startAuthenticatorSetup,
} from '../lib/api.js';
import './EmployeeSignIn.css';

const ISSUER = 'A&E RV Solutions';

// The /employees/ page. Everything shown after sign-in comes from the
// employee API (GET /me) and Cognito, never from the site build.
export default function EmployeeSignIn() {
  // loading | unconfigured | signedOut | signedIn
  const [status, setStatus] = useState('loading');
  const [user, setUser] = useState(null);
  const [me, setMe] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!signInConfigured) {
      setStatus('unconfigured');
      return;
    }
    let cancelled = false;
    (async () => {
      let signedIn = null;
      try {
        signedIn = (await completeSignIn()) ?? (await currentUser());
      } catch {
        if (!cancelled) setError('Sign-in didn’t complete. Please try again.');
      }
      if (cancelled) return;
      if (!signedIn) {
        setStatus('signedOut');
        return;
      }
      const result = await getEmployeeMe(signedIn.id_token);
      if (cancelled) return;
      if (result.status === 'ok') {
        setUser(signedIn);
        setMe(result.me);
        setStatus('signedIn');
      } else {
        setError(
          result.status === 'unauthorized'
            ? 'Your session has ended. Please sign in again.'
            : 'We couldn’t load the employee area. Please try again shortly.',
        );
        setStatus('signedOut');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (status === 'loading') {
    return <p className="employee-sign-in__muted">Checking sign-in…</p>;
  }

  if (status === 'unconfigured') {
    return (
      <div className="employee-sign-in">
        <h1 className="employee-sign-in__title">Employees</h1>
        <p>Employee sign-in isn’t available right now.</p>
      </div>
    );
  }

  if (status === 'signedOut') {
    return (
      <div className="employee-sign-in">
        <h1 className="employee-sign-in__title">Employees</h1>
        <p>Sign in with your A&amp;E RV Solutions employee account.</p>
        {error && (
          <p className="employee-sign-in__error" role="alert">
            {error}
          </p>
        )}
        <button className="employee-sign-in__button" type="button" onClick={() => signIn()}>
          Sign in
        </button>
      </div>
    );
  }

  return (
    <div className="employee-sign-in">
      <h1 className="employee-sign-in__title">{me.title}</h1>
      {me.isAdmin && (
        <p>
          <a className="employee-sign-in__link" href="/admin/">
            Admin: AI usage and conversations
          </a>
        </p>
      )}
      {me.body && <p>{me.body}</p>}
      <AccountSecurity accessToken={user.access_token} email={me.email} />
    </div>
  );
}

// Authenticator app and passkeys for the signed-in employee.
function AccountSecurity({ accessToken, email }) {
  const [security, setSecurity] = useState(null);
  const [loadError, setLoadError] = useState(false);
  const [settingUp, setSettingUp] = useState(false);
  const [removing, setRemoving] = useState('');
  const [removeError, setRemoveError] = useState('');

  const remove = async (passkey) => {
    if (!window.confirm(`Remove the passkey "${passkey.name}"? You won't be able to sign in with it.`)) return;
    setRemoving(passkey.id);
    setRemoveError('');
    try {
      await removePasskey(accessToken, passkey.id);
      await load();
    } catch {
      setRemoveError('Couldn’t remove that passkey. Please try again.');
    }
    setRemoving('');
  };

  const load = () =>
    getAccountSecurity(accessToken)
      .then((result) => {
        setSecurity(result);
        setLoadError(false);
      })
      .catch(() => setLoadError(true));

  useEffect(() => {
    load();
  }, [accessToken]);

  return (
    <section className="employee-sign-in__section" aria-labelledby="account-security">
      <h2 className="employee-sign-in__subtitle" id="account-security">
        Account security
      </h2>

      {loadError && (
        <p className="employee-sign-in__error" role="alert">
          We couldn’t load your security settings. Sign out and sign in again.
        </p>
      )}
      {!security && !loadError && <p className="employee-sign-in__muted">Loading…</p>}

      {security && (
        <ul className="employee-sign-in__list">
          <li className="employee-sign-in__item">
            <div>
              <p className="employee-sign-in__label">Authenticator app</p>
              <p className="employee-sign-in__muted">
                {security.authenticator
                  ? 'Set up. Password sign-ins ask for a code from it.'
                  : 'Required for every employee. Protects password sign-ins.'}
              </p>
            </div>
            {!security.authenticator && !settingUp && (
              <button
                className="employee-sign-in__button"
                type="button"
                onClick={() => setSettingUp(true)}
              >
                Set up authenticator app
              </button>
            )}
          </li>

          {settingUp && (
            <li>
              <AuthenticatorSetup
                accessToken={accessToken}
                email={email}
                onDone={() => {
                  setSettingUp(false);
                  load();
                }}
                onCancel={() => setSettingUp(false)}
              />
            </li>
          )}

          <li className="employee-sign-in__item">
            <div>
              <p className="employee-sign-in__label">Passkeys</p>
              <p className="employee-sign-in__muted">
                {security.passkeys.length === 0
                  ? 'None yet. Sign in with your fingerprint, face, or device PIN instead of a password.'
                  : 'Sign in with any of these. Your device must confirm it’s you (PIN, fingerprint, or face) each time.'}
              </p>
            </div>
            <a className="employee-sign-in__button" href={addPasskeyUrl()}>
              Add a passkey
            </a>
            {security.passkeys.length > 0 && (
              <ul className="employee-sign-in__passkeys">
                {security.passkeys.map((passkey) => (
                  <li className="employee-sign-in__passkey" key={passkey.id}>
                    <span>
                      {passkey.name}
                      {passkey.createdAt && (
                        <span className="employee-sign-in__muted">
                          {' '}
                          · added {passkey.createdAt.toLocaleDateString()}
                        </span>
                      )}
                    </span>
                    <button
                      className="employee-sign-in__button employee-sign-in__button--quiet"
                      type="button"
                      disabled={removing === passkey.id}
                      onClick={() => remove(passkey)}
                    >
                      {removing === passkey.id ? 'Removing…' : 'Remove'}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            {removeError && (
              <p className="employee-sign-in__error" role="alert">
                {removeError}
              </p>
            )}
          </li>
        </ul>
      )}
    </section>
  );
}

function AuthenticatorSetup({ accessToken, email, onDone, onCancel }) {
  const codeId = useId();
  const [secret, setSecret] = useState('');
  const [qr, setQr] = useState('');
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    startAuthenticatorSetup(accessToken)
      .then(async (secretCode) => {
        const label = encodeURIComponent(`${ISSUER}:${email}`);
        const uri = `otpauth://totp/${label}?secret=${secretCode}&issuer=${encodeURIComponent(ISSUER)}`;
        const image = await QRCode.toDataURL(uri, { margin: 1, width: 200 });
        if (!cancelled) {
          setSecret(secretCode);
          setQr(image);
        }
      })
      .catch(() => !cancelled && setError('Couldn’t start setup. Sign out and sign in again.'));
    return () => {
      cancelled = true;
    };
  }, [accessToken, email]);

  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      await finishAuthenticatorSetup(accessToken, code.trim());
      onDone();
    } catch (err) {
      setError(
        err.code === 'EnableSoftwareTokenMFAException' || err.code === 'CodeMismatchException'
          ? 'That code didn’t match. Enter the newest code from the app.'
          : err.message,
      );
      setBusy(false);
    }
  };

  return (
    <form className="employee-sign-in__setup" onSubmit={submit}>
      <p>
        In an authenticator app (Google Authenticator, Microsoft Authenticator, 1Password…), add
        an account by scanning this code:
      </p>
      {qr ? (
        <img
          className="employee-sign-in__qr"
          src={qr}
          width="200"
          height="200"
          alt="QR code for adding your A&E employee account to an authenticator app"
        />
      ) : (
        !error && <p className="employee-sign-in__muted">Preparing…</p>
      )}
      {secret && (
        <p className="employee-sign-in__muted">
          Can’t scan it? Enter this key instead:{' '}
          <code className="employee-sign-in__secret">{secret}</code>
        </p>
      )}
      <label className="employee-sign-in__label" htmlFor={codeId}>
        Then enter the 6-digit code it shows
      </label>
      <input
        id={codeId}
        className="employee-sign-in__input"
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]{6}"
        maxLength={6}
        required
        value={code}
        onChange={(event) => setCode(event.target.value.replace(/\D/g, ''))}
      />
      {error && (
        <p className="employee-sign-in__error" role="alert">
          {error}
        </p>
      )}
      <div className="employee-sign-in__actions">
        <button className="employee-sign-in__button" type="submit" disabled={busy || !secret}>
          {busy ? 'Checking…' : 'Verify and turn on'}
        </button>
        <button
          className="employee-sign-in__button employee-sign-in__button--quiet"
          type="button"
          onClick={onCancel}
        >
          Cancel
        </button>
      </div>
    </form>
  );
}
