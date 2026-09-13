import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  createBotMatch, createMatch, joinMatch, leaveRanked, rankedTick, sweepMatches,
} from '../lib/api'
import { Comics } from './Comics'
import {
  BOT_LEVELS, DECK_SIZE, tierOf,
  type LadderRow, type MatchRow, type Profile,
} from '../lib/types'
import { fieldable } from '../lib/kingdoms'
import { useT } from '../lib/i18n'
import { useCards } from '../lib/useCards'
import { Avatar } from './Avatar'
import { IconGear } from './Icons'
import { AdminCards } from './AdminCards'
import { Kingdoms } from './Kingdoms'
import { Tournament } from './Tournament'
import { KingdomSwitch } from './KingdomSwitch'
import { Logo } from './Logo'
import { ProfileCard } from './ProfileCard'
import { SettingsCard } from './SettingsCard'
import { Page, useZoom } from './Zoom'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
  /** The lobby owns the profile panel, so it is the lobby that reports a new
   *  name or face back up to whoever is holding the profile. */
  onProfile: (patch: Partial<Profile>) => void
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
  /* Backstage, and only for the one account that has the flag. There is no
     picture behind it and there should not be: every other tile is a door into
     the game and this one is a door into the workings. A missing background is
     invisible rather than broken -- the tile is simply its own flat colour. */
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

export function Lobby({ profile, onEnter, onProfile }: Props) {
  const t = useT()
  const { zoomTo, close, page, zoomer } = useZoom()
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
      .order('lp', { ascending: false }).order('wins', { ascending: false }).limit(50)
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
  // The page a tile opens is usually titled with the tile's own label; Watch
  // is the one that is not, because "Watch" names an action and the page is a
  // list of matches.
  const title = (id: PageId) => t(id === 'spectate' ? 'lobby.liveMatches' : TILE_TITLE[id])
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
            <span className="whoami-name">{profile.username}</span>
            {profile.games > 0 && (
              <span className="ownrank">{tierName(tierOf(profile.lp))} {profile.lp}</span>
            )}
          </button>
          <button className="iconbtn" onClick={() => setOverlay('settings')} aria-label={t('common.settings')}>
            <IconGear />
          </button>
        </div>
      </header>

      <nav className="menu-grid">
        {(profile.is_admin ? TILES : PLAYER_TILES).map((tile_) => (
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
              <span className="mtile-label">{t(TILE_TITLE[tile_.id])}</span>
              <span className="mtile-note">
                {tile_.id === 'team' && !deckSet ? t('lobby.notChosenYet')
                 : tile_.id === 'team' && currentName ? currentName
                 : tile_.id === 'ladder' && profile.games > 0
                   ? t('lobby.yourStanding', { tier: tierName(tierOf(profile.lp)), lp: profile.lp })
                   : t(TILE_NOTE[tile_.id])}
              </span>
            </span>
          </button>
        ))}
      </nav>

      {err && <p className="error menu-err">{err}</p>}
      {zoomer}

      {overlay === 'profile' && (
        <ProfileCard profile={profile} onClose={() => setOverlay(null)} onChanged={onProfile} />
      )}
      {overlay === 'settings' && <SettingsCard onClose={() => setOverlay(null)} />}

      {page && tile && (
        <Page
          title={title(tile.id)} tint={tile.tint} onClose={close}
          wide={page === 'team' || page === 'admin' || page === 'tournament'}
        >
          {page === 'ranked' && (
            <div className="modelist">
              <KingdomSwitch profile={profile} onProfile={onProfile} />
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
            </div>
          )}

          {/* Opening a room and joining one used to be two tiles, which made
              the menu ask a question nobody has: whether you are the host. You
              want to play a specific person; one of you sends five letters. */}
          {page === 'friends' && (
            <div className="modelist">
              <KingdomSwitch profile={profile} onProfile={onProfile} />
              <button className="modecard" disabled={busy} onClick={() => run(createMatch)}>
                <span className="modecard-name">{t('friends.openRoom')}</span>
                <span className="modecard-note">{t('friends.openRoomNote')}</span>
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
            </div>
          )}

          {page === 'comics' && <Comics />}

          {/* Guarded here as well as in the menu. Nothing else opens this page,
              but a screen whose only lock is that its door is not drawn is not
              locked -- and the real lock, the RLS policy on `cards`, is on the
              server where it belongs. */}
          {page === 'admin' && profile.is_admin && <AdminCards />}

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
            <Kingdoms profile={profile} roster={roster} onProfile={onProfile} />
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
                            {r.username}
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
    </div>
  )
}
