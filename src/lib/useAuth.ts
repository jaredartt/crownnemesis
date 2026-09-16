import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import { hydrate, unlink } from './settings'
import type { Profile } from './types'

/** Every column the current client needs that a older schema would not have.
 *  Checked by presence rather than by asking for it, so a database that is a
 *  migration behind gives us a clear answer instead of a failed query. */
const REQUIRED_COLUMNS = ['deck'] as const

const BEHIND =
  'This build needs a database migration that has not been run yet. ' +
  'Open the Supabase SQL editor and run supabase/migrations/0005_roster_terrain_deploy.sql.'

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const [profileError, setProfileError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  // Since 0039. Set the moment this browser learns its own account is
  // banned -- either from the profile row it just fetched, or from the
  // Realtime row that arrives while it is sitting in the lobby -- and left
  // set through the sign-out that follows, so the screen that replaces the
  // app can say why rather than just dumping the player back at the login
  // form with no explanation.
  const [banned, setBanned] = useState(false)

  const retryProfile = useCallback(() => {
    setProfileError(null)
    setAttempt((n) => n + 1)
  }, [])

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) {
      setProfile(null)
      setProfileError(null)
      // The settings stay -- they are still this browser's -- but there is
      // nothing to write them to until somebody signs in again.
      unlink()
      return
    }
    // A fresh session -- somebody just signed in -- so whatever this browser
    // remembered about a PREVIOUS account's ban does not apply to this one.
    setBanned(false)
    let cancelled = false
    // The profile row is created by a trigger, which can land a beat after the
    // session does. Retry a few times before giving up.
    ;(async () => {
      let last: string | null = null
      for (let i = 0; i < 6 && !cancelled; i++) {
        // select('*') on purpose. Naming the columns means the whole sign-in
        // fails the moment the app expects one the database has not got yet --
        // and since the site deploys instantly while a migration is run by
        // hand, that window is real. A star cannot go stale.
        const { data, error } = await supabase
          .from('profiles')
          .select('*')
          .eq('id', session.user.id)
          .maybeSingle()

        if (data) {
          if (cancelled) return
          const missing = REQUIRED_COLUMNS.filter((c) => !(c in data))
          if (missing.length) setProfileError(BEHIND)
          else {
            // The account's settings win over this browser's cache, and
            // whatever the account is missing gets pushed up once -- which is
            // how somebody who had settings here before 0022 keeps them.
            // Deliberately NOT in REQUIRED_COLUMNS: a database that has not
            // run 0022 yet should still let you play, with the cache doing
            // exactly what it did before.
            hydrate((data as { settings?: unknown }).settings)
            setProfile(data as Profile)
            // Signed in already banned -- offline when it happened, or this
            // is a page load rather than a live session. Realtime below is
            // for the second one; this is the first.
            if ((data as Profile).is_banned) {
              setBanned(true)
              void supabase.auth.signOut()
            }
          }
          return
        }
        if (error) last = error.message
        await new Promise((r) => setTimeout(r, 400))
      }
      // Six tries and still nothing. Say so: an unexplained spinner is the
      // worst way to report a problem, because it looks like it is working.
      if (!cancelled) {
        setProfileError(last ?? 'Your profile could not be loaded. It may not have been created.')
      }
    })()
    return () => {
      cancelled = true
    }
  }, [session, attempt])

  /** Fold a change made elsewhere -- a new name, a new face -- into the copy
   *  every screen is reading from, without a round trip to fetch what we just
   *  wrote. */
  const patchProfile = useCallback((patch: Partial<Profile>) => {
    setProfile((p) => (p ? { ...p, ...patch } : p))
  }, [])

  // Since 0039. One row, this account's own, watched for exactly one change:
  // is_banned flipping to true. This is the fast path admin_set_banned()
  // promises in its own comment -- "kicked to the login screen within a
  // second or two" -- and it is deliberately narrow. It does not watch for a
  // new username or a new avatar; ProfileCard already patches those locally
  // the moment it saves them, and a second source of truth for the same
  // fields is how two screens disagree about which one is right.
  useEffect(() => {
    const uid = session?.user.id
    if (!uid) return
    const channel = supabase
      .channel(`own-profile:${uid}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'profiles', filter: `id=eq.${uid}` },
        (payload) => {
          const row = payload.new as Partial<Profile> | undefined
          if (row?.is_banned) {
            setBanned(true)
            void supabase.auth.signOut()
          }
        },
      )
      .subscribe()
    return () => { supabase.removeChannel(channel) }
  }, [session?.user.id])

  /** The banned screen's own way back to the login form -- signing out
   *  again would be a no-op (Realtime already did it), this just stops the
   *  app from continuing to show the reason after the player has read it. */
  const acknowledgeBanned = useCallback(() => setBanned(false), [])

  return {
    session, profile, loading, profileError, retryProfile, patchProfile,
    banned, acknowledgeBanned, userId: session?.user.id ?? null,
  }
}
