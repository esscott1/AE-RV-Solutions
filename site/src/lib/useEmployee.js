import { useEffect, useState } from 'react';
import { currentUser, signInConfigured } from './auth.js';

// The signed-in employee for a page island: {status, user, isAdmin}.
// status is loading | unconfigured | signedOut | signedIn. isAdmin comes
// from the ID token's cognito:groups and only decides what to show; the API
// checks the group itself.
export function useEmployee() {
  const [state, setState] = useState({ status: 'loading', user: null, isAdmin: false });

  useEffect(() => {
    if (!signInConfigured) {
      setState({ status: 'unconfigured', user: null, isAdmin: false });
      return;
    }
    currentUser()
      .then((user) => {
        if (!user) {
          setState({ status: 'signedOut', user: null, isAdmin: false });
          return;
        }
        const groups = user.profile?.['cognito:groups'];
        setState({ status: 'signedIn', user, isAdmin: Array.isArray(groups) && groups.includes('admins') });
      })
      .catch(() => setState({ status: 'signedOut', user: null, isAdmin: false }));
  }, []);

  return state;
}
