import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Auth } from './components/Auth'
import { Lobby } from './components/Lobby'
import { Match } from './components/Match'
import { RoyaleMatch } from './components/RoyaleMatch'
import { Tutorial } from './components/Tutorial'
import { Boundary } from './components/Boundary'
import { Logo } from './components/Logo'
import { useWipe } from './components/Wipe'
import { attachUiSounds } from './lib/sfx'
import { primeLang, useT } from './lib/i18n'
import { useAuth } from './lib/useAuth'
import { refreshProgression, useProgression } from './lib/progression'
import { useMusicCategory } from './lib/useMusic'
import { setSettings, useSettings } from './lib/settings'
import { dropOpenTournamentSignup, myBanAppeals, sendTournamentGoingAway, submitBanAppeal, touchPresence } from './lib/api'
import { useMyTournament } from './lib/useMyTournament'
import type { BanAppeal } from './lib/types'
import { configured, supabase } from './lib/supabase'

/**
 * The one door out of the banned screen -- see 0062_ban_appeals.sql. A
 * banned account's Supabase session is still valid here (see the comment on
 * the `banned` block below), which is what makes a SECURITY DEFINER RPC keyed
 * off auth.uid() sound: nobody but the still-signed-in banned account itself
 * can call submit_ban_appeal(). One pending appeal at a time is enforced
 * server-side, so this only needs to show three states -- nothing sent yet,
 * one waiting on a reply, or the last one came back denied.
 */
function BanAppealPanel() {
  const t = useT()
  const [appeals, setAppeals] = useState<BanAppeal[] | null>(null)
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    myBanAppeals().then((rows) => { if (alive) setAppeals(rows) })
    return () => { alive = false }
  }, [])

  async function submit() {
    setBusy(true); setErr(null)
    try {
      const row = await submitBanAppeal(message)
      setAppeals((rows) => [row, ...(rows ?? [])])
      setMessage('')
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(false)
    }
  }

  // Still loading -- say nothing rather than flash the form and yank it away.
  if (appeals === null) return null

  const pending = appeals.find((a) => a.status === 'pending')
  const lastDenied = !pending && appeals.find((a) => a.status === 'denied')

  if (pending) return <p className="muted tiny banappeal-status">{t('app.appealPending')}</p>

  return (
    <div className="banappeal">
      {lastDenied && <p className="muted tiny banappeal-status">{t('app.appealDenied')}</p>}
      <label className="banappeal-field">
        <span>{t('app.appealLabel')}</span>
        <textarea
          value={message} onChange={(e) => setMessage(e.target.value)}
          maxLength={2000} rows={3} disabled={busy}
        />
      </label>
      <div className="actionbar" style={{ marginTop: 10, justifyContent: 'flex-start' }}>
        <button
          type="button" className="btn ghost small" disabled={busy || !message.trim()}
          onClick={() => void submit()}
        >
          {busy ? t('app.appealSending') : t('app.appealSend')}
        </button>
      </div>
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}

/** The one account Admin Mode ever opens for. Checked here, alongside
 *  `profile.is_admin`, rather than trusting is_admin alone -- see 0039's own
 *  comment on cn_is_super_admin() for why a flag that is usually only true
 *  for one person is not the same statement as a check that names the
 *  person. Lower-cased on both sides: an email's case is not part of its
 *  identity. */
const SUPER_ADMIN_EMAIL = 'jaredartt@gmail.com'

export default function App() {
  const t = useT()
  const {
    session, profile, loading, profileError, retryProfile, patchProfile,
    banned, acknowledgeBanned,
  } = useAuth()
  // 0188: the levels/skins catalogs are readable only when signed in, so they
  // are (re)fetched once the profile is there -- and reading them here makes
  // the whole tree repaint when they land (name-colour skins are plain style
  // helpers with no hook of their own).
  useProgression()
  const uid = profile?.id
  useEffect(() => { if (uid) void refreshProgression() }, [uid])
  // Jared: a simple scripted lesson (two kings, one unit a side, no trees)
  // right after an account is created, skippable, replayable from Settings.
  // Driven straight off the account's own tutorialSeen setting rather than
  // a separate piece of state here -- 0 for a brand new account (settings
  // starts as {}, so the key is simply absent) and true for everyone who
  // existed before this shipped (see the one-time backfill migration), so
  // "just created" needs no extra bookkeeping of its own: it IS the account
  // that has never carried this key. Settings' own "Replay tutorial" row
  // flips it back to false, which is all it takes to bring this back too.
  const settings = useSettings()
  const showTutorial = Boolean(session) && Boolean(profile) && !banned && !settings.tutorialSeen
  const [matchId, setMatchId] = useState<string | null>(
    () => new URLSearchParams(location.search).get('m'),
  )
  // Battle Royale's own id, kept apart from `matchId` -- a person is never in
  // both at once, but they are two different tables and two different
  // screens, so this is its own URL param ('r') rather than overloading 'm'.
  const [royaleId, setRoyaleId] = useState<string | null>(
    () => new URLSearchParams(location.search).get('r'),
  )

  // Both halves of the lock, not is_admin alone. See SUPER_ADMIN_EMAIL above.
  const canAdmin = Boolean(profile?.is_admin)
    && (session?.user.email ?? '').toLowerCase() === SUPER_ADMIN_EMAIL

  // One player of music for the whole app -- see useMusic.ts. Menu while in
  // the lobby, battle while in a match, nothing while signed out or banned.
  const musicCategory = useMemo<'menu' | 'battle' | null>(() => {
    if (!session || !profile || banned) return null
    return matchId || royaleId ? 'battle' : 'menu'
  }, [session, profile, banned, matchId, royaleId])
  useMusicCategory(musicCategory)
  // Every crossing between the menu and a match goes through this, in both
  // directions: leaving one for the other used to happen in a single frame.
  const { cross, wipe } = useWipe()

  // Stable identities. These are effect dependencies down in Match, and a
  // fresh arrow on every render makes those effects re-run on every render --
  // which is how a rematch used to leave the wipe covering the screen.
  const goTo = useCallback((id: string) => cross(() => setMatchId(id)), [cross])
  const leave = useCallback(() => cross(() => setMatchId(null)), [cross])
  const goToRoyale = useCallback((id: string) => cross(() => setRoyaleId(id)), [cross])
  const leaveRoyale = useCallback(() => cross(() => setRoyaleId(null)), [cross])

  // One pair of listeners for every button in the app, rather than a sound
  // wired into each one and forgotten on the next.
  useEffect(attachUiSounds, [])

  // "This account is somewhere in the app right now" -- for the Friends
  // list's online dot. Same shape as useMatch.ts's own 10s heartbeat, just
  // slower and for the whole session rather than one room; touch_presence()
  // rejects a signed-out caller on its own, so this only needs to stop
  // ticking once signed out or banned, not to double-check either here.
  useEffect(() => {
    if (!session || !profile || banned) return
    touchPresence()
    const beat = setInterval(touchPresence, 20_000)
    return () => clearInterval(beat)
  }, [session, profile, banned])

  // 0192/0194: closing or RELOADING the tab while signed up for an open
  // tournament takes the name off the sign-up list at once (the server also
  // sweeps anyone whose heartbeat has gone quiet, and the boot check below
  // catches a goodbye that never arrived).
  const { entry: myTourney, loaded: tourneyLoaded } = useMyTournament(session && profile && !banned ? profile.id : undefined)
  const signedUpOpen = myTourney?.status === 'open'
  // A sign-up that is still there on the FIRST read of this page load was left
  // by a reload/close whose goodbye never arrived: take it off. (Later joins
  // in this page session happen after this read, so they are never touched.)
  const bootChecked = useRef(false)
  useEffect(() => {
    if (!tourneyLoaded || bootChecked.current) return
    bootChecked.current = true
    if (myTourney?.status === 'open') void dropOpenTournamentSignup()
  }, [tourneyLoaded, myTourney])
  useEffect(() => {
    if (!signedUpOpen) return
    const bye = () => sendTournamentGoingAway()
    window.addEventListener('pagehide', bye)
    return () => window.removeEventListener('pagehide', bye)
  }, [signedUpOpen])

  // Fetch the dictionary for whatever language the cache already says, before
  // anything asks for a word. Without it the first paint is English and the
  // second is Spanish, which is a flicker in front of the one person who
  // notices it most.
  useEffect(primeLang, [])

  // Keep the URL in step, so a match is a link you can paste to a spectator.
  useEffect(() => {
    const url = new URL(location.href)
    if (matchId) url.searchParams.set('m', matchId)
    else url.searchParams.delete('m')
    if (royaleId) url.searchParams.set('r', royaleId)
    else url.searchParams.delete('r')
    history.replaceState(null, '', url)
  }, [matchId, royaleId])

  if (!configured) {
    return (
      <div className="center-stage">
        <div className="panel">
          <h1 className="wordmark small">{t('app.almostThere')}</h1>
          <p className="muted">
            Copy <code>.env.example</code> to <code>.env.local</code>, paste in your Supabase
            project URL and anon key, then restart <code>npm run dev</code>.
          </p>
        </div>
      </div>
    )
  }

  if (loading)
    return (
      <div className="center-stage">
        <Logo className="logo logo-hero is-waiting" title="Crown Nemesis" />
      </div>
    )
  // Checked before `!session`: the sign-out Realtime just triggered has
  // already cleared the session by the time a player reads this, and the
  // whole point is that they see WHY they are back at the door rather than
  // the ordinary login form with no explanation.
  if (banned)
    return (
      <div className="center-stage">
        <div className="panel">
          <h1 className="wordmark small">{t('app.banned')}</h1>
          <p className="muted">{t('app.bannedNote')}</p>
          <BanAppealPanel />
          <div className="actionbar" style={{ marginTop: 18, justifyContent: 'flex-start' }}>
            <button className="btn" onClick={acknowledgeBanned}>{t('common.backToMenu')}</button>
          </div>
        </div>
      </div>
    )
  if (!session) return <Auth />
  if (!profile)
    return (
      <div className="center-stage">
        <div className="panel">
          <h1 className="wordmark small">
            {t(profileError ? 'app.notReady' : 'app.loading')}
          </h1>
          <p className="muted">{profileError ?? t('app.gettingReady')}</p>
          {profileError && (
            <div className="actionbar" style={{ marginTop: 18, justifyContent: 'flex-start' }}>
              <button className="btn" onClick={retryProfile}>{t('app.tryAgain')}</button>
              <button className="btn ghost" onClick={() => supabase.auth.signOut()}>
                {t('common.signOut')}
              </button>
            </div>
          )}
        </div>
      </div>
    )
  if (matchId)
    return (
      <>
        {/* The match is the part with the most moving pieces and the only part
            where a crash strands you mid-turn, so it gets its own boundary
            with a way OUT of it -- the lobby is still standing behind this. */}
        <Boundary where="match" onOut={leave}>
          <Match
            matchId={matchId} profile={profile} onProfile={patchProfile}
            onLeave={leave} onGoTo={goTo}
          />
        </Boundary>
        {wipe}
      </>
    )
  if (royaleId)
    return (
      <>
        <Boundary where="match" onOut={leaveRoyale}>
          <RoyaleMatch matchId={royaleId} profile={profile} onLeave={leaveRoyale} onProfile={patchProfile} />
        </Boundary>
        {wipe}
      </>
    )
  if (showTutorial)
    return (
      <>
        <Tutorial onDone={() => setSettings({ tutorialSeen: true })} />
        {wipe}
      </>
    )

  return (
    <>
      <Lobby
        profile={profile}
        onEnter={goTo}
        onEnterRoyale={goToRoyale}
        onProfile={patchProfile}
        canAdmin={canAdmin}
      />
      {wipe}
    </>
  )
}
