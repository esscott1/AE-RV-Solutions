import { useEffect, useId, useRef, useState } from 'react';
import { onUserChange, signedInUser, signOut } from '../lib/auth.js';
import './AccountMenu.css';

// The signed-in employee's name at the top right of signed-in pages, like
// the AWS console: click it for a menu with Sign out. Shows nothing while
// signed out (the page itself offers Sign in).
export default function AccountMenu() {
  const [user, setUser] = useState(null);
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const rootRef = useRef(null);
  const buttonRef = useRef(null);

  useEffect(() => {
    signedInUser().then(setUser).catch(() => setUser(null));
    return onUserChange(setUser);
  }, []);

  // Esc closes the menu (focus back on the button); a click outside closes it.
  useEffect(() => {
    if (!open) return;
    const onKey = (event) => {
      if (event.key === 'Escape') {
        setOpen(false);
        buttonRef.current?.focus();
      }
    };
    const onClick = (event) => {
      if (!rootRef.current?.contains(event.target)) setOpen(false);
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('click', onClick);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('click', onClick);
    };
  }, [open]);

  if (!user) return null;

  const email = user.profile?.email ?? 'Account';

  return (
    <div className="account-menu" ref={rootRef}>
      <button
        type="button"
        ref={buttonRef}
        className="account-menu__toggle"
        aria-haspopup="true"
        aria-expanded={open}
        aria-controls={menuId}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="account-menu__name">{email}</span>
        <span className="account-menu__caret" aria-hidden="true">
          ▾
        </span>
      </button>
      {open && (
        <div className="account-menu__panel" id={menuId}>
          <p className="account-menu__signed-in">
            Signed in as
            <span className="account-menu__email">{email}</span>
          </p>
          <button type="button" className="account-menu__item" onClick={() => signOut()} autoFocus>
            Sign out
          </button>
        </div>
      )}
    </div>
  );
}
