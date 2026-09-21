import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  createBotMatch, createMatch, createRoyaleBotMatch, createRoyaleMatch, joinMatch,
  joinRoyaleMatch, leaveRanked, rankedTick, sweepMatches,
} from '../lib/api'
import { Comics } from './Comics'
import { Friends } from './Friends'
import { NotificationsBell } from './NotificationsBell'
import {
  BOT_LEVELS, DECK_SIZE, tierOf,
  type LadderRow, type MatchRow, type Profile,
} from '../lib/types'
import { fieldable } from '../lib/kingdoms'
import { currentLang, useT } from '../lib/i18n'
import { useCards } from '../lib/useCards'
import { useMenuSections } from '../lib/useMenuSections'
import { primeContentOverrides } from '../lib/useContentOverrides'
import { Avatar } from './Avatar'
import { AddFriendButton } from './AddFriendButton'
import { IconDiscord, IconGear, IconInstagram } from './Icons'
import { AdminPanel } from './AdminPanel'
import { Kingdoms } from './Kingdoms'
import { Tournament } from './Tournament'
import { KingdomSwitch } from './KingdomSwitch'
import { Logo } from './Logo'
import { ProfileCard } from './ProfileCard'
import { nameColorStyle } from '../lib/nameColors'
import { SettingsCard } from './SettingsCard'
import { Page, useZoom } from './Zoom'
import { Modal } from './Modal'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
  /** Battle Royale's own entry point -- a different table, a different
   *  screen, so App.tsx hands it a separate id to cross into. */
  onEnterRoyale: (matchId: string) => void
  /** The lobby owns the profile panel, so it is the lobby that reports a new
   *  name or face back up to whoever is holding the profile. */
  onProfile: (patch: Partial<Profile>) => void
  /** Both halves of 0039's lock, decided once in App.tsx: is_admin AND the
   *  signed-in email. Admin Mode no longer has a tile of its own in the menu
   *  grid -- it opens from the bottom of Settings, and this is what decides
   *  whether that door is even drawn there. */
  canAdmin: boolean
}

/** Every destination: its colour, the picture behind it, and where its tile
 *  sits. The colour is used three times -- washed over the picture, on the
 *  block that flies out of the tile, and on the band at the top of the page it
 *  lands on -- which is what ties the three together.
 *
 *  `focus` is where the picture is anchored inside a tile far wider than the
 *  picture is: a lower number shows more of the top of it. It is per tile
 *  because these are drawings of people, and one number that keeps every head
 *  on screen does not exist -- the ladder's is a square portrait in a letterbox
 *  and the practice one is a figure standing at the top of a staircase.
 *
 *  Ranked has no picture yet, so its tile is the flat colour until one lands
 *  in public/menu/. A missing background is invisible, not broken. */
const TILES = [
  { id: 'ranked',   tint: '#d92d20', art: 'menu/ranked.webp',   focus: '22%' },
  { id: 'bot',      tint: '#e8701a', art: 'menu/practice.webp', focus: '0%'  },
  { id: 'friends',  tint: '#d9a41b', art: 'menu/friends.webp',  focus: '28%' },
  { id: 'spectate', tint: '#2f9e52', art: 'menu/watch.webp',    focus: '32%' },
  { id: 'ladder',   tint: '#2f4bff', art: 'cards/dereo.webp',   focus: '14%' },
  { id: 'team',     tint: '#7c3aed', art: 'menu/team.webp',     focus: '26%' },
  { id: 'tournament', tint: '#ef7c1f', art: 'menu/tournament.webp', focus: '26%' },
  { id: 'comics',   tint: '#0f8b8d', art: 'menu/comics.webp',   focus: '4%'  },
  /* Last of the player tiles, which puts it bottom-right at every width the
     grid wraps at -- where the spec asked for it. No picture yet; the flat
     colour is what a missing background looks like, and it looks deliberate
     rather than broken. */
  /* Backstage. Since 0039 this is no longer a tile in the grid at all -- Admin
     Mode opens from the bottom of Settings, behind canAdmin, not from a click
     here -- but the id stays in TILES because the Page it opens still wants a
     tint and a title, and TILE_TITLE/TILE_NOTE below still key off it. */
  { id: 'admin',    tint: '#3f3f56', art: '',                   focus: '0%'  },
] as const

/** The tiles that are doors into the game rather than into its workings. */
const PLAYER_TILES = TILES.filter((t) => t.id !== 'admin')

type PageId = (typeof TILES)[number]['id']

/**
 * The dictionary key for each tile, written out literally.
 *
 * `t(`lobby.${id}`)` is how this used to read, and it is exactly the mistake
 * the project's own rule warns about: a CONSTRUCTED key is invisible to a
 * search and invisible to the i18n check. The tile called 'practice' was
 * renamed to 'bot' and the two keys were not, so the menu showed the literal
 * string "lobby.bot" to every player for weeks and no tool could have told
 * anybody. As a Record over PageId, a tile without a key is a compile error.
 */
const TILE_TITLE: Record<PageId, string> = {
  ranked: 'lobby.ranked', bot: 'lobby.bot', friends: 'lobby.friends',
  spectate: 'lobby.spectate', ladder: 'lobby.ladder', team: 'lobby.team',
  comics: 'lobby.comics', tournament: 'lobby.tournament', admin: 'lobby.admin',
}
const TILE_NOTE: Record<PageId, string> = {
  ranked: 'lobby.rankedNote', bot: 'lobby.botNote', friends: 'lobby.friendsNote',
  spectate: 'lobby.spectateNote', ladder: 'lobby.ladderNote', team: 'lobby.teamNote',
  comics: 'lobby.comicsNote', tournament: 'lobby.tournamentNote',
  admin: 'lobby.adminNote',
}

/** Community links for the slim footer at the bottom of the menu.
 *  Not constants any more -- read live below through `t('lobby.discordUrl')`
 *  / `t('lobby.instagramUrl')`, the exact same menu_content_overrides
 *  mechanism 0046 built for rewriting any bundled string from Admin Mode.
 *  The two keys below are only the BUNDLED fallback (see en.json/es.json):
 *  Jared can change the live URL any time, for every signed-in player at
 *  once, with no deploy, from Admin Mode -> Menu -> Content overrides,
 *  keyed by 'lobby.discordUrl' / 'lobby.instagramUrl' -- same door every
 *  other piece of menu text already goes through, and already writable by
 *  cn_is_super_admin() alone (see 0046_admin_content_and_delete.sql's RLS). */

export function Lobby({ profile, onEnter, onEnterRoyale, onProfile, canAdmin }: Props) {
  const t = useT()
  // Since 0046: warms menu_content_overrides the same way primeLang() warms
  // the language dictionary -- once, here, so that by the time anything
  // below calls t() the cache is either already there or already on its way.
  useEffect(primeContentOverrides, [])
  const { zoomTo, close, page, zoomer } = useZoom()
  // My Kingdom's own "anything the server has not confirmed yet" -- told to
  // us by Kingdoms itself via onDirtyChange, since this file owns the door
  // out of that page (Page's back arrow / Escape) and Kingdoms does not. A
  // value left over here from a previous visit can never wrongly gate a
  // LATER close on some other page -- closePage only ever reads it while
  // page === 'team', which is exactly when Kingdoms is mounted and keeping
  // it current.
  const [kingdomDirty, setKingdomDirty] = useState(false)
  const [confirmLeaveKingdom, setConfirmLeaveKingdom] = useState(false)
  const closePage = useCallback(() => {
    if (page === 'team' && kingdomDirty) { setConfirmLeaveKingdom(true); return }
    close()
  }, [page, kingdomDirty, close])
  // The button that opens Settings doubles as the animation's origin when
  // Settings itself opens Admin Mode -- there is no tile to grow from
  // anymore, so this is the closest thing on screen to "where that door is".
  const gearRef = useRef<HTMLButtonElement>(null)
  // Origin for the "choose your deck" button on the Ranked page, when it
  // needs to zoom into the Team page the same way a tile click would.
  const rankedDeckRef = useRef<HTMLButtonElement>(null)
  const [rooms, setRooms] = useState<MatchRow[]>([])
  // The roster, from the cache every screen shares. It used to be fetched when
  // My Kingdom opened; the menu itself now needs it, because which kingdom you
  // are fielding is a question you cannot answer without knowing which cards
  // are still in the game.
  const roster = useCards()
  const [ladder, setLadder] = useState<LadderRow[]>([])
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  // queue
  const [overlay, setOverlay] = useState<null | 'profile' | 'settings'>(null)

  const [searching, setSearching] = useState(false)
  const [waiting, setWaiting] = useState(0)
  const [elapsed, setElapsed] = useState(0)
  const since = useRef(0)

  const run = useCallback(
    async (fn: () => Promise<{ id: string }>) => {
      setBusy(true); setErr(null)
      try { onEnter((await fn()).id) } catch (e) { setErr((e as Error).message); close() }
      finally { setBusy(false) }
    },
    [onEnter, close],
  )
  // Same shape, for the royale room's own create/join pair -- see the
  // friends page below.
  const [royaleCode, setRoyaleCode] = useState('')
  // Item 4: which of the two room kinds is open in the Vs Friends panel,
  // if either. Only ADD FRIEND and the two picker buttons show until one
  // is chosen -- the code/join UI for a mode is revealed by choosing it,
  // not always sitting open beneath it.
  const [roomMode, setRoomMode] = useState<'1v1' | '4p' | null>(null)
  // The Vs Bots page's own royale picker: how many bots (1-3, never forced
  // to exactly three) and at what shared difficulty -- see
  // create_royale_bot_match, which takes one level per opponent but is
  // handed the same level N times from here for simplicity.
  const [royaleBotCount, setRoyaleBotCount] = useState(3)
  const [royaleBotLevel, setRoyaleBotLevel] = useState(2)
  const runRoyale = useCallback(
    async (fn: () => Promise<{ id: string }>) => {
      setBusy(true); setErr(null)
      try { onEnterRoyale((await fn()).id) } catch (e) { setErr((e as Error).message); close() }
      finally { setBusy(false) }
    },
    [onEnterRoyale, close],
  )

  // ---- room list, for the watch page --------------------------------------
  useEffect(() => {
    if (page !== 'spectate') return
    let alive = true
    const load = async () => {
      await sweepMatches()
      // Practice is not a spectacle. A bot match is you and a machine, so it
      // is left off the list entirely -- the room still exists and its code
      // still works, so a friend you hand it to can walk in and watch. It is
      // simply not advertised.
      const { data } = await supabase
        .from('matches').select('*')
        .in('status', ['waiting', 'deploying', 'active'])
        .is('bot', null)
        .order('created_at', { ascending: false }).limit(20)
      if (alive && data) setRooms(data as MatchRow[])
    }
    load()
    const id = setInterval(load, 4000)
    return () => { alive = false; clearInterval(id) }
  }, [page])

  useEffect(() => {
    if (page !== 'ladder') return
    supabase.from('leaderboard').select('*')
      // Item 6: every registered player belongs here now, not just
      // ones with games > 0 (0065 dropped that filter server-side) --
      // 500 is comfortably "all" today and still a real bound.
      .order('lp', { ascending: false }).order('wins', { ascending: false }).limit(500)
      .then(({ data }) => data && setLadder(data as LadderRow[]))
  }, [page])

  // ---- the queue -----------------------------------------------------------
  useEffect(() => {
    if (!searching) return
    let alive = true
    const tick = async () => {
      try {
        const q = await rankedTick()
        if (!alive) return
        setWaiting(q.waiting)
        if (q.match) { setSearching(false); onEnter(q.match) }
      } catch (e) {
        if (alive) { setErr((e as Error).message); setSearching(false) }
      }
    }
    tick()
    const poll = setInterval(tick, 2000)
    const clock = setInterval(() => setElapsed(Math.floor((Date.now() - since.current) / 1000)), 500)
    return () => { alive = false; clearInterval(poll); clearInterval(clock) }
  }, [searching, onEnter])

  // Leaving the page, or the app, drops you out rather than leaving a ghost in
  // the queue for someone to be paired against.
  useEffect(() => {
    if (page !== 'ranked' && searching) { setSearching(false); leaveRanked() }
  }, [page, searching])
  useEffect(() => {
    const bye = () => { if (searching) leaveRanked() }
    window.addEventListener('pagehide', bye)
    return () => { window.removeEventListener('pagehide', bye); bye() }
  }, [searching])

  // Which army the next match will actually use, worked out the same way
  // deck_of() works it out. The client has to agree with the server here or
  // the menu claims one kingdom while the board fields another.
  const bySlug = useMemo(() => new Map(roster.map((c) => [c.slug, c])), [roster])

  // Live from menu_sections (0042): which of PLAYER_TILES are shown, and in
  // what order. A tile this table has no row for yet -- a fresh database that
  // has not run 0042, or a future tile this build knows about before the
  // table does -- stays visible at its usual position rather than vanishing,
  // the same fail-open choice useAuth.ts makes for a settings column that is
  // not there yet: a menu with a missing row should look normal, not empty.
  const sections = useMenuSections()
  const sectionById = useMemo(() => new Map(sections.map((sec) => [sec.id, sec])), [sections])
  const shownTiles = useMemo(
    () => PLAYER_TILES
      .filter((tl) => sectionById.get(tl.id)?.visible !== false)
      .slice()
      .sort((a, b) => {
        const sa = sectionById.get(a.id)?.sort ?? PLAYER_TILES.indexOf(a)
        const sb = sectionById.get(b.id)?.sort ?? PLAYER_TILES.indexOf(b)
        return sa - sb
      }),
    [sectionById],
  )

  const kingdoms = profile.kingdoms ?? []
  const current = kingdoms.find((k) => k.id === profile.kingdom) ?? null
  const deckSet = !!current && roster.length > 0 && fieldable(current.deck, bySlug)
  const effectiveDeck = deckSet && current
    ? current.deck
    : roster.slice(0, DECK_SIZE).map((c) => c.slug)
  const currentName = current
    ? current.name || t('kingdom.untitled', { n: kingdoms.indexOf(current) + 1 })
    : ''

  const tile = TILES.find((x) => x.id === page)
  // Since 0046: an admin can write a title/note straight onto the
  // menu_sections row, ahead of the dictionary key -- see AdminMenu.tsx.
  // Null (the default, and everything before this migration) falls through
  // to the same t(TILE_TITLE[id]) / t(TILE_NOTE[id]) this always read, so a
  // tile nobody has touched from the panel looks exactly as it always has.
  const es = currentLang() === 'es'
  const tileTitle = (id: PageId) => {
    const override = es ? sectionById.get(id)?.title_es : sectionById.get(id)?.title_en
    return override || t(TILE_TITLE[id])
  }
  const tileNote = (id: PageId) => {
    const override = es ? sectionById.get(id)?.subtitle_es : sectionById.get(id)?.subtitle_en
    return override || t(TILE_NOTE[id])
  }
  // The page a tile opens is usually titled with the tile's own label; Watch
  // is the one that is not, because "Watch" names an action and the page is a
  // list of matches.
  const title = (id: PageId) => (id === 'spectate' ? t('lobby.liveMatches') : tileTitle(id))
  // Tier names come off the ladder as English words, and a tier is a word
  // rather than a number, so it is translated the same as anything else.
  const tierName = (tier: string) => t(`tier.${tier.toLowerCase()}`)

  return (
    <div className="menu">
      <header className="menu-head">
        <div className="brand">
          <Logo className="logo" title="Crown Nemesis" />
          <h1 className="wordmark small">CROWN NEMESIS</h1>
        </div>
        <div className="menu-who">
          {/* One button, not two: the face and the name are the same thing to
              point at, and splitting them would make the smaller of the two a
              target you have to aim for. */}
          <button className="whoami" onClick={() => setOverlay('profile')}>
            <Avatar slug={profile.avatar} name={profile.username} size={30} />
            <span className="whoami-name" style={nameColorStyle(profile.name_color)}>{profile.username}</span>
            {/* Jared: "I don't want names, I just want the ranked points
                there" -- the tier name (Bronze, Silver, ...) still shows in
                the fuller "You are {tier} on {lp} LP" standing line
                elsewhere on this page; this one spot, the small badge next
                to your own name in the header, is just the number now. */}
            {profile.games > 0 && (
              <span className="ownrank">{t('lobby.ownRankPoints', { lp: profile.lp })}</span>
            )}
          </button>
          <NotificationsBell
            profile={profile}
            onJoinMatch={onEnter}
            onJoinRoyale={onEnterRoyale}
            onOpenTournament={() => {
              if (gearRef.current) zoomTo(gearRef.current, { id: 'tournament', tint: '#ef7c1f' })
            }}
          />
          <button
            ref={gearRef} className="iconbtn"
            onClick={() => setOverlay('settings')} aria-label={t('common.settings')}
          >
            <IconGear />
          </button>
        </div>
      </header>

      <nav className="menu-grid">
        {shownTiles.map((tile_) => (
          <button
            key={tile_.id}
            className={`mtile mt-${tile_.id}`}
            style={{ '--tint': tile_.tint } as React.CSSProperties}
            disabled={busy}
            onClick={(e) => zoomTo(e.currentTarget, { id: tile_.id, tint: tile_.tint })}
          >
            {/* Three layers: the picture, the colour laid over it, and the
                words. The picture is counter-skewed and overscaled so the lean
                never exposes a corner, and it is the only thing that moves on
                hover -- the tile itself holds still and its colour thins out. */}
            <span
              className="mtile-art"
              style={{
                backgroundImage: `url(${import.meta.env.BASE_URL}${tile_.art})`,
                backgroundPosition: `center ${tile_.focus}`,
              }}
              aria-hidden="true"
            />
            <span className="mtile-wash" aria-hidden="true" />
            <span className="mtile-inner">
              <span className="mtile-label">{tileTitle(tile_.id)}</span>
              <span className="mtile-note">
                {tile_.id === 'team' && !deckSet ? t('lobby.notChosenYet')
                 : tile_.id === 'team' && currentName ? currentName
                 : tile_.id === 'ladder' && profile.games > 0
                   ? t('lobby.yourStanding', { tier: tierName(tierOf(profile.lp)), lp: profile.lp })
                   : tileNote(tile_.id)}
              </span>
            </span>
          </button>
        ))}
      </nav>

      {err && <p className="error menu-err">{err}</p>}

      <footer className="menu-social">
        <a href={t('lobby.discordUrl')} target="_blank" rel="noreferrer" aria-label={t('lobby.discord')}>
          <IconDiscord />
        </a>
        <a href={t('lobby.instagramUrl')} target="_blank" rel="noreferrer" aria-label={t('lobby.instagram')}>
          <IconInstagram />
        </a>
      </footer>

      {zoomer}

      {overlay === 'profile' && (
        <ProfileCard profile={profile} onClose={() => setOverlay(null)} onChanged={onProfile} />
      )}
      {overlay === 'settings' && (
        <SettingsCard
          onClose={() => setOverlay(null)}
          canAdmin={canAdmin}
          onOpenAdmin={() => {
            setOverlay(null)
            if (gearRef.current) zoomTo(gearRef.current, { id: 'admin', tint: '#3f3f56' })
          }}
        />
      )}

      {page && tile && (
        <Page
          title={title(tile.id)} tint={tile.tint} onClose={closePage}
          wide={page === 'team' || page === 'admin' || page === 'tournament'}
        >
          {page === 'ranked' && (
            <div className="modelist">
              <KingdomSwitch profile={profile} onProfile={onProfile} />
              <button
                ref={rankedDeckRef}
                type="button"
                className="btn ghost small rankeddeck-btn"
                onClick={() => {
                  if (rankedDeckRef.current) zoomTo(rankedDeckRef.current, { id: 'team', tint: '#7c3aed' })
                }}
              >
                {t('ranked.editDeck')}
              </button>
              <button
                className={`modecard${searching ? ' is-live' : ''}`}
                onClick={() => { since.current = Date.now(); setElapsed(0); setSearching(true) }}
                disabled={searching}
              >
                <span className="modecard-name">{t('ranked.oneVsOne')}</span>
                <span className="modecard-note">
                  {searching
                    ? t('ranked.searching', { seconds: elapsed, waiting })
                    : t('ranked.blurb')}
                </span>
              </button>
              {searching && (
                <>
                  <p className="muted tiny queuenote">{t('ranked.fussy')}</p>
                  <button className="btn ghost" onClick={() => { setSearching(false); leaveRanked() }}>
                    {t('common.cancel')}
                  </button>
                </>
              )}
              {!deckSet && (
                <p className="muted tiny queuenote">
                  {t('ranked.noDeck', {
                    deck: effectiveDeck.join(', ') || t('ranked.defaultFive'),
                  })}
                </p>
              )}
            </div>
          )}

          {page === 'bot' && (
            <div className="modelist">
              <KingdomSwitch profile={profile} onProfile={onProfile} />
              {BOT_LEVELS.map((b) => (
                <button
                  key={b.level}
                  className="modecard"
                  disabled={busy}
                  onClick={() => run(() => createBotMatch(b.level))}
                >
                  {/* BOT_LEVELS keeps the level number and nothing else that
                      is words: CALM, SHARP and RUTHLESS are names and their
                      notes are sentences, and both belong to the dictionary. */}
                  <span className="modecard-name">{t(`bot.${b.key}`)}</span>
                  <span className="modecard-note">{t(`bot.${b.key}Note`)}</span>
                </button>
              ))}
              <p className="muted tiny queuenote">{t('bot.blurb')}</p>

              <div className="orline"><span>{t('royale.title')}</span></div>
              {/* 0052: the same Vs Bots screen also opens a full royale
                  match against 1-3 bots -- one shared difficulty (the seg
                  control) rather than one picker per bot, and a count
                  toggle for how many opponents to face. */}
              <div className="rbotpicker">
                <span className="muted tiny">{t('royale.numBots')}</span>
                <div className="seg" role="radiogroup" aria-label={t('royale.numBots')}>
                  {[1, 2, 3].map((n) => (
                    <button
                      key={n}
                      type="button"
                      role="radio"
                      aria-checked={royaleBotCount === n}
                      className={royaleBotCount === n ? 'is-on' : ''}
                      onClick={() => setRoyaleBotCount(n)}
                    >
                      {n}
                    </button>
                  ))}
                </div>
              </div>
              <div className="rbotpicker">
                <span className="muted tiny">{t('royale.botDifficulty')}</span>
                <div className="seg" role="radiogroup" aria-label={t('royale.botDifficulty')}>
                  {BOT_LEVELS.map((b) => (
                    <button
                      key={b.level}
                      type="button"
                      role="radio"
                      aria-checked={royaleBotLevel === b.level}
                      className={royaleBotLevel === b.level ? 'is-on' : ''}
                      onClick={() => setRoyaleBotLevel(b.level)}
                    >
                      {t(`bot.${b.key}`)}
                    </button>
                  ))}
                </div>
              </div>
              <button
                className="modecard"
                disabled={busy}
                onClick={() => runRoyale(
                  () => createRoyaleBotMatch(Array(royaleBotCount).fill(royaleBotLevel)),
                )}
              >
                <span className="modecard-name">{t('royale.vsBotsStart')}</span>
                <span className="modecard-note">{t('royale.vsBotsNote')}</span>
              </button>
            </div>
          )}

          {/* Opening a room and joining one used to be two tiles, which made
              the menu ask a question nobody has: whether you are the host. You
              want to play a specific person; one of you sends five letters. */}
          {page === 'friends' && (
            <div className="modelist">
              <KingdomSwitch profile={profile} onProfile={onProfile} />
              <Friends profile={profile} onEnter={onEnter} onEnterRoyale={onEnterRoyale} />

              {/* Item 4: two doors, not two rooms sitting open underneath a
                  friends list. Nothing past this pair renders until one is
                  picked -- clicking is what reveals its code/join UI. */}
              <div className="roommode-pick">
                <button
                  type="button"
                  className={`modecard${roomMode === '1v1' ? ' is-live' : ''}`}
                  disabled={busy}
                  onClick={() => setRoomMode(roomMode === '1v1' ? null : '1v1')}
                >
                  <span className="modecard-name">{t('friends.openRoom')}</span>
                  <span className="modecard-note">{t('friends.openRoomNote')}</span>
                </button>
                <button
                  type="button"
                  className={`modecard${roomMode === '4p' ? ' is-live' : ''}`}
                  disabled={busy}
                  onClick={() => setRoomMode(roomMode === '4p' ? null : '4p')}
                >
                  <span className="modecard-name">{t('royale.openRoom')}</span>
                  <span className="modecard-note">{t('royale.openRoomNote')}</span>
                </button>
              </div>

              {roomMode === '1v1' && (
                <>
                  <button
                    className="btn primary big roommode-open"
                    disabled={busy}
                    onClick={() => run(createMatch)}
                  >
                    {t('friends.openRoom')}
                  </button>
                  <div className="orline"><span>{t('common.or')}</span></div>
                  <form
                    className="joinform"
                    onSubmit={(e) => { e.preventDefault(); if (code.trim()) run(() => joinMatch(code)) }}
                  >
                    <input
                      className="codeinput" value={code} maxLength={5} aria-label={t('friends.roomCode')}
                      onChange={(e) => setCode(e.target.value.toUpperCase())}
                      placeholder={t('friends.codePlaceholder')}
                    />
                    <button className="btn primary" disabled={busy || !code.trim()}>
                      {t('common.join')}
                    </button>
                  </form>
                  <p className="muted tiny queuenote">{t('friends.noRating')}</p>
                </>
              )}

              {roomMode === '4p' && (
                <>
                  <button
                    className="btn primary big roommode-open"
                    disabled={busy}
                    onClick={() => runRoyale(createRoyaleMatch)}
                  >
                    {t('royale.openRoom')}
                  </button>
                  <div className="orline"><span>{t('common.or')}</span></div>
                  <form
                    className="joinform"
                    onSubmit={(e) => {
                      e.preventDefault()
                      if (royaleCode.trim()) runRoyale(() => joinRoyaleMatch(royaleCode))
                    }}
                  >
                    <input
                      className="codeinput" value={royaleCode} maxLength={5}
                      aria-label={t('friends.roomCode')}
                      onChange={(e) => setRoyaleCode(e.target.value.toUpperCase())}
                      placeholder={t('friends.codePlaceholder')}
                    />
                    <button className="btn primary" disabled={busy || !royaleCode.trim()}>
                      {t('common.join')}
                    </button>
                  </form>
                </>
              )}
            </div>
          )}

          {page === 'comics' && <Comics />}

          {/* Guarded here as well as at the Settings row that opens it. Nothing
              else opens this page, but a screen whose only lock is that its
              door is not drawn is not locked -- and the real lock is on the
              server: cn_is_super_admin() in 0039_super_admin.sql, which every
              write AdminPanel's tabs can make is checked against regardless
              of what this line does or does not render. */}
          {page === 'admin' && canAdmin && <AdminPanel />}

          {/* The bracket lives in its own file: it polls, it is the referee
              for every stalled match in the tournament, and none of that
              belongs in a menu. */}
          {page === 'tournament' && <Tournament profile={profile} onEnter={onEnter} />}

          {page === 'spectate' && (
            <>
              {rooms.length === 0 && <p className="muted">{t('spectate.nothing')}</p>}
              <ul className="roomlist">
                {rooms.map((r) => {
                  const mine = r.host_id === profile.id || r.guest_id === profile.id
                  const open = r.status === 'waiting' && !mine
                  return (
                    <li key={r.id}>
                      <span className="code">{r.code}</span>
                      <span className="names">
                        {r.host_name}
                        {r.guest_name
                          ? ` ${t('spectate.vs')} ${r.guest_name}`
                          : ` — ${t('spectate.waitingForOpponent')}`}
                      </span>
                      <span className={`pill ${r.status}`}>{t(`status.${r.status}`)}</span>
                      <button
                        className="btn small" disabled={busy}
                        onClick={() => (open ? run(() => joinMatch(r.code)) : onEnter(r.id))}
                      >
                        {t(mine ? 'common.return' : open ? 'common.join' : 'common.watch')}
                      </button>
                    </li>
                  )
                })}
              </ul>
            </>
          )}

          {/* Ten of them now, and the one you field. Everything that used to
              be here -- the roster grid, the picking, the saving with no save
              button -- moved into Kingdoms so the page could grow a shelf
              above it without this file growing a second screen. */}
          {page === 'team' && (
            <Kingdoms
              profile={profile} roster={roster} onProfile={onProfile}
              onDirtyChange={setKingdomDirty}
            />
          )}

          {page === 'ladder' && (
            <>
              {ladder.length === 0 && <p className="muted">{t('ladder.empty')}</p>}
              {ladder.length > 0 && (
                <table className="ladder">
                  <thead>
                    <tr>
                      <th className="num">#</th><th>{t('ladder.player')}</th>
                      <th>{t('ladder.tier')}</th>
                      <th className="num">{t('ladder.lp')}</th>
                      <th className="num">{t('ladder.w')}</th>
                      <th className="num">{t('ladder.l')}</th>
                      <th className="num">{t('ladder.streak')}</th>
                      <th className="num" title={t('ladder.cupsNote')}>{t('ladder.cups')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ladder.map((r, i) => (
                      <tr key={r.id} className={r.id === profile.id ? 'is-you' : ''}>
                        <td className="num rank">{i + 1}</td>
                        <td>
                          {/* A face, at last: the leaderboard view never
                              selected `avatar`, so LadderRow has carried the
                              field with nothing behind it since 0016. */}
                          <span className="ladder-who">
                            <Avatar slug={r.avatar} name={r.username} size={26} />
                            <span style={nameColorStyle(r.name_color)}>{r.username}</span>
                            {/* Item 6: a friend button per row that doesn't collide with
                                anything -- .ladder-who is already a flex row with its own
                                gap, so this just becomes its next child, same as the
                                identical pattern beside an opponent's name in Match.tsx. */}
                            <AddFriendButton userId={profile.id} targetId={r.id} />
                          </span>
                        </td>
                        <td>
                          <span className={`tier t-${r.tier.toLowerCase()}`}>
                            {tierName(r.tier)}
                          </span>
                        </td>
                        <td className="num lp">{r.lp}</td>
                        <td className="num">{r.wins}</td>
                        <td className="num">{r.losses}</td>
                        <td className={`num streak ${r.streak > 0 ? 'hot' : r.streak < 0 ? 'cold' : ''}`}>
                          {r.streak > 0 ? `${r.streak}${t('ladder.w')}`
                           : r.streak < 0 ? `${-r.streak}${t('ladder.l')}`
                           : t('common.dash')}
                        </td>
                        {/* Zero for everybody until Phase E fills it. The
                            column is here now so the table settles once
                            rather than shifting under everybody later. */}
                        <td className="num cups">
                          {r.tournaments ? r.tournaments : t('common.dash')}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              <p className="muted tiny laddernote">{t('ladder.note')}</p>
            </>
          )}
          {err && <p className="error">{err}</p>}
        </Page>
      )}

      {/* My Kingdom's own confirm -- see closePage's own comment. The other
          pages this same door serves need nothing here: this page is the
          only one with something that can be lost by leaving it. */}
      {confirmLeaveKingdom && (
        <Modal
          title={t('kingdom.confirmLeaveTitle')}
          onClose={() => setConfirmLeaveKingdom(false)}
        >
          <div className="actionbar">
            <button className="btn ghost" onClick={() => setConfirmLeaveKingdom(false)}>
              {t('common.cancel')}
            </button>
            <button
              className="btn danger"
              onClick={() => { setConfirmLeaveKingdom(false); close() }}
            >
              {t('kingdom.confirmLeaveYes')}
            </button>
          </div>
        </Modal>
      )}
    </div>
  )
}
