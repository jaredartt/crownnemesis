import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  createBotMatch, createMatch, createRoyaleBotMatch, createRoyaleMatch, getRating, joinMatch,
  joinRoyaleMatch, leaveRanked, rankedTick, sweepMatches,
} from '../lib/api'
import { Comics } from './Comics'
import { Friends } from './Friends'
import { NotificationsBell } from './NotificationsBell'
import {
  BOT_LEVELS, DECK_SIZE,
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

// Player is alphabetical; every other column is a LadderRow stat sorted
// numerically. "#" (rank) is deliberately not one of these -- see the
// comment beside .ladder-sortbtn in styles.css.
type LadderSortField = 'player' | 'rating' | 'wins' | 'streak' | 'tournaments'

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
export const TILES = [
  /* The front-door tile. Opens a small hub (below, page === 'play') with
     Ranked / Vs Friends / Vs Bots inside it, rather than going straight into
     matchmaking the way the old Ranked tile did -- its art and tint are
     Ranked's own, since it is visually the same tile, just relabelled and
     one tap further in. */
  { id: 'play',     tint: '#d92d20', art: 'menu/ranked.webp',   focus: '22%' },
  /* 'ranked', 'bot' and 'friends' stay in TILES -- they are still real
     PageIds, opened from inside the Play hub the same way a front-page tile
     opens one -- MENU_TILES below is what keeps them off the front page. */
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

/** Ranked, Vs Bots and Vs Friends no longer get a button of their own on the
 *  front page -- Play (above) opens straight into a hub with all three, so
 *  drawing them again out here would be the same three doors twice. */
const HUB_ONLY: readonly string[] = ['ranked', 'bot', 'friends']
const MENU_TILES = PLAYER_TILES.filter((t) => !HUB_ONLY.includes(t.id))
/** Looked up by id rather than re-typed -- the Play hub's three doors reuse
 *  Ranked/Vs Friends/Vs Bots' own tint, art and focus point from TILES
 *  rather than carrying a second copy of them. */
const tileById = (id: PageId) => TILES.find((x) => x.id === id)!

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
  play: 'lobby.play',
  ranked: 'lobby.ranked', bot: 'lobby.bot', friends: 'lobby.friends',
  spectate: 'lobby.spectate', ladder: 'lobby.ladder', team: 'lobby.team',
  comics: 'lobby.comics', tournament: 'lobby.tournament', admin: 'lobby.admin',
}
const TILE_NOTE: Record<PageId, string> = {
  play: 'lobby.playNote',
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

/** One rhomboid tile -- the picture, the colour wash, and the label --
 *  shared by the front page's own grid and the Play hub's three doors, so
 *  both are drawn, hovered and enter the same way with no second copy of
 *  any of it to drift out of sync with the first. */
const MAX_TILT_DEG = 7

/** Which side of the layout a tile sits on -- Play/Ranked and Team on the
    left, Comics/Tournament/Ladder and Friends/Bots on the right (Watch/
    Spectate sits in the middle and is left alone). Jared: art on left-side
    tiles reads as shifted further left, right-side tiles further right --
    nudging each group's background-position the opposite way is what
    "centers" them; "center" alone (the old value, same for every tile) is
    what let it happen, since it never accounted for which side a tile
    itself sits on. */
const LEFT_TILES = new Set(['play', 'ranked', 'team'])
const RIGHT_TILES = new Set(['comics', 'tournament', 'ladder', 'friends', 'bot'])
// Jared: My Kingdom's own art (team.webp) was cropping its cast off the left
// edge -- the shared 58% LEFT_TILES bias, tuned for Play/Ranked's own
// pieces, crops harder than this particular drawing can afford, since its
// figures already reach close to both of ITS edges. Centred instead of
// biased fixed that side, and see .mt-team's own scale-down in styles.css
// for the rest of that first pass. Since revised again below -- centre
// turned out to still be cropping the RIGHT side of the same cast, hence
// hBias('team') no longer matching this comment's own "centred" claim.
export function hBias(id: string) {
  // Jared, this round: "move it to the right so that all characters fit" --
  // dead centre was still letting the cast run off the tile's own right
  // edge (see the vertical-band fix on .mt-team .mtile-art in styles.css
  // for the OTHER half of this same complaint). Shifted right of centre,
  // short of LEFT_TILES' own 58% (tuned for Play/Ranked's different art,
  // and the exact value this drawing was cropping AT before the centre fix
  // below it undid) -- best static guess without a live render to check
  // against; nudge further if the cast still doesn't fully clear the edge.
  if (id === 'team') return '64%'
  if (LEFT_TILES.has(id)) return '58%'
  if (RIGHT_TILES.has(id)) return '42%'
  return 'center'
}

/** An admin's own crop for one tile -- see artOverride() below. Any field
 *  left null falls through to that tile's existing hand-tuned hBias()/
 *  `focus`/resting-scale, exactly as if 0087 had never been touched for it. */
export interface ArtOverride {
  x: number | null
  y: number | null
  zoom: number | null
}

function MenuTile({
  id, tint, art, focus, label, note, disabled, onClick, artOverride,
}: {
  id: string
  tint: string
  art: string
  focus: string
  label: string
  note: string
  disabled?: boolean
  onClick: (e: React.MouseEvent<HTMLButtonElement>) => void
  /** Admin Mode -> Menu -> Tiles' own x/y/zoom for this tile (0087), or
   *  undefined on the (rare) call site that hasn't been wired to it. */
  artOverride?: ArtOverride
}) {
  const artRef = useRef<HTMLSpanElement>(null)
  // Skipped entirely under reduced-motion, same as the float this rides
  // alongside -- both are motion the user never asked for by touching
  // anything, cursor position included.
  const onMove = (e: React.MouseEvent<HTMLButtonElement>) => {
    const el = artRef.current
    if (!el || disabled) return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const rect = e.currentTarget.getBoundingClientRect()
    const nx = (e.clientX - rect.left) / rect.width - 0.5    // -0.5..0.5
    const ny = (e.clientY - rect.top) / rect.height - 0.5
    el.style.setProperty('--tilt-ry', `${(nx * MAX_TILT_DEG * 2).toFixed(2)}deg`)
    el.style.setProperty('--tilt-rx', `${(-ny * MAX_TILT_DEG * 2).toFixed(2)}deg`)
  }
  const onLeave = () => {
    const el = artRef.current
    if (!el) return
    el.style.setProperty('--tilt-rx', '0deg')
    el.style.setProperty('--tilt-ry', '0deg')
  }
  return (
    <button
      className={`mtile mt-${id}`}
      style={{ '--tint': tint } as React.CSSProperties}
      disabled={disabled}
      onClick={onClick}
      onMouseMove={onMove}
      onMouseLeave={onLeave}
    >
      {/* Three layers: the picture, the colour laid over it, and the words.
          The picture is counter-skewed and overscaled so the lean never
          exposes a corner, and it is the only thing that moves on hover --
          the tile itself holds still and its colour thins out. It also
          tilts a little toward the cursor (--tilt-rx/--tilt-ry, set above),
          on top of the float, while hovered. */}
      <span
        ref={artRef}
        className="mtile-art"
        style={{
          backgroundImage: `url(${import.meta.env.BASE_URL}${art})`,
          // Jared: "move them a little to the right, left, up or down... or
          // zooming them or unzooming them" -- an admin's own x/y (0087)
          // takes over from hBias()/focus for THIS tile only when set;
          // --art-zoom multiplies onto the tile's own resting/hover scale
          // in styles.css rather than replacing it, so a tile nobody has
          // touched in Admin Mode keeps rendering pixel-identical to before.
          backgroundPosition:
            `${artOverride?.x != null ? `${artOverride.x}%` : hBias(id)} `
            + `${artOverride?.y != null ? `${artOverride.y}%` : focus}`,
          ...(artOverride?.zoom != null
            ? { '--art-zoom': (artOverride.zoom / 100).toFixed(3) } as React.CSSProperties
            : null),
        }}
        aria-hidden="true"
      />
      <span className="mtile-wash" aria-hidden="true" />
      <span className="mtile-inner">
        <span className="mtile-label">{label}</span>
        <span className="mtile-note">{note}</span>
      </span>
    </button>
  )
}

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
  const [rooms, setRooms] = useState<MatchRow[]>([])
  // The roster, from the cache every screen shares. It used to be fetched when
  // My Kingdom opened; the menu itself now needs it, because which kingdom you
  // are fielding is a question you cannot answer without knowing which cards
  // are still in the game.
  const roster = useCards()
  const [ladder, setLadder] = useState<LadderRow[]>([])
  // Jared: "if you press any of the columns, it will be ordered by that."
  // Defaults to the same order the fetch below already asks the server
  // for (rating desc, wins desc as the tiebreak) so turning this on
  // doesn't reorder anything until a header is actually clicked.
  const [ladderSort, setLadderSort] = useState<{ field: LadderSortField; dir: 'asc' | 'desc' }>({
    field: 'rating', dir: 'desc',
  })
  // 0082: rating lives in player_rating now, not on the profiles row --
  // fetched once here (not gated to the ladder page, since the header
  // badge shows it too) and kept at 1000 until it resolves, same as
  // getRating()'s own fallback for a player with no row yet.
  const [myRating, setMyRating] = useState(1000)
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
  // Jared: "can you put it like this, the mode called Vs Bots? I think it
  // makes more sense" -- the same two-doors idea as roomMode above, now for
  // Vs Bots' own two shapes (a solo 1v1 or a full royale table), so this
  // page opens the way the Friends page already does rather than showing a
  // list of three difficulties immediately followed by a whole second
  // picker for a different mode underneath.
  const [botMode, setBotMode] = useState<'1v1' | '4p' | null>(null)
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
      .order('rating', { ascending: false }).order('wins', { ascending: false }).limit(500)
      .then(({ data }) => data && setLadder(data as LadderRow[]))
  }, [page])

  // Clicking the column already driving the sort flips its direction;
  // clicking a new one switches to it at that column's own natural default
  // (A-Z for Player, best-first for every stat).
  const toggleLadderSort = useCallback((field: LadderSortField) => {
    setLadderSort((s) => (
      s.field === field
        ? { field, dir: s.dir === 'asc' ? 'desc' : 'asc' }
        : { field, dir: field === 'player' ? 'asc' : 'desc' }
    ))
  }, [])

  const sortedLadder = useMemo(() => {
    const { field, dir } = ladderSort
    const mul = dir === 'asc' ? 1 : -1
    return [...ladder].sort((a, b) => {
      if (field === 'player') return mul * a.username.localeCompare(b.username)
      const av = field === 'tournaments' ? (a.tournaments ?? 0) : field === 'wins' ? a.wins : field === 'streak' ? a.streak : a.rating
      const bv = field === 'tournaments' ? (b.tournaments ?? 0) : field === 'wins' ? b.wins : field === 'streak' ? b.streak : b.rating
      if (av !== bv) return mul * (av - bv)
      // Tiebreak always reads best-first, whichever direction the active
      // column itself is currently sorted, so equal values don't jump
      // around between renders.
      if (a.rating !== b.rating) return b.rating - a.rating
      return b.wins - a.wins
    })
  }, [ladder, ladderSort])

  // 0082: own rating, independent of the ladder page -- the header badge
  // reads it whenever profile.games > 0, whatever page is open.
  useEffect(() => {
    let alive = true
    getRating(profile.id).then((r) => { if (alive) setMyRating(r) })
    return () => { alive = false }
  }, [profile.id, profile.games])

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

  // Landing on this page IS the request for a match again -- see the
  // comment on the ranked page below for why the picker in between got
  // un-shipped. Re-fires every time `page` becomes 'ranked', including
  // arriving a second time after cancelling once, since the effect's own
  // condition is what gates it, not a one-shot ref.
  useEffect(() => {
    if (page === 'ranked') { since.current = Date.now(); setElapsed(0); setSearching(true) }
  }, [page])
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
    () => MENU_TILES
      .filter((tl) => sectionById.get(tl.id)?.visible !== false)
      .slice()
      .sort((a, b) => {
        const sa = sectionById.get(a.id)?.sort ?? MENU_TILES.indexOf(a)
        const sb = sectionById.get(b.id)?.sort ?? MENU_TILES.indexOf(b)
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
  // The one bit of per-tile note logic that isn't just "read the dictionary
  // key" -- My Kingdom shows what's actually equipped and Ladder shows your
  // actual standing, once there is one. Shared by the flat grid tiles and
  // the ones inside .mtile-stack, which is the only reason this is a
  // function and not still written out inline twice.
  const noteFor = (id: PageId) =>
    id === 'team' && !deckSet ? t('lobby.notChosenYet')
    : id === 'team' && currentName ? currentName
    : id === 'ladder' && profile.games > 0
      ? t('lobby.yourStanding', { lp: myRating })
      : tileNote(id)
  // Since 0087: an admin's own crop for this tile, or every field null on a
  // tile nobody has touched from the panel -- see ArtOverride/MenuTile above.
  // 'play' is the front-door tile that opens the hub -- it has no
  // menu_sections row of its own (nothing to toggle visible/sort on a door
  // that's never hidden), so its crop rides on 'ranked''s: same art, same
  // tint, "visually the same tile, just relabelled and one tap further in"
  // (see TILES above). Without this alias an admin's Ranked crop only ever
  // showed up once you'd already tapped through to the hub -- the front
  // page kept its default crop regardless, which is what "this one
  // specifically doesn't work" (Jared) was actually seeing.
  const artOverride = (id: PageId): ArtOverride => {
    const s = sectionById.get(id === 'play' ? 'ranked' : id)
    return { x: s?.art_x ?? null, y: s?.art_y ?? null, zoom: s?.art_zoom ?? null }
  }

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
            {/* 0082: the raw rating, same spot it has always lived --
                there is no tier name to leave out of this one any more, the
                fuller "You are {lp} RP" standing line elsewhere on this page
                lost it too. */}
            {profile.games > 0 && (
              <span className="ownrank">{t('lobby.ownRankPoints', { lp: myRating })}</span>
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
        {shownTiles
          .filter((tl) => tl.id !== 'tournament' && tl.id !== 'ladder')
          .map((tile_) => (
            <MenuTile
              key={tile_.id}
              id={tile_.id} tint={tile_.tint} art={tile_.art} focus={tile_.focus}
              label={tileTitle(tile_.id)} note={noteFor(tile_.id)}
              disabled={busy} artOverride={artOverride(tile_.id)}
              onClick={(e) => zoomTo(e.currentTarget, { id: tile_.id, tint: tile_.tint })}
            />
          ))}
        {/* Tournaments and Ladder share one skewed frame instead of each
            leaning on its own -- see .mtile-stack in styles.css for why: two
            tiles half Play's height, skewed independently, meet Play's own
            edge at two different offsets and the seam breaks into a visible
            zigzag instead of one clean diagonal. One shared skew, split by a
            plain (unskewed) divider between them, is what the mockup itself
            actually shows. */}
        {shownTiles.some((tl) => tl.id === 'tournament' || tl.id === 'ladder') && (
          <div className="mtile-stack">
            {/* Tournament above Ladder, always -- fixed by the layout itself
                (see .mtile-stack in styles.css), not by wherever Admin Mode's
                menu_sections.sort happens to have put them relative to each
                other; .filter() alone would have used shownTiles' own order,
                which by default puts Ladder first (MENU_TILES lists it
                before Tournament) and stacked them backwards. */}
            {(['tournament', 'ladder'] as const)
              .map((id) => shownTiles.find((tl) => tl.id === id))
              .filter((tl): tl is NonNullable<typeof tl> => tl != null)
              .map((tile_) => (
                <MenuTile
                  key={tile_.id}
                  id={tile_.id} tint={tile_.tint} art={tile_.art} focus={tile_.focus}
                  label={tileTitle(tile_.id)} note={noteFor(tile_.id)}
                  disabled={busy} artOverride={artOverride(tile_.id)}
                  onClick={(e) => zoomTo(e.currentTarget, { id: tile_.id, tint: tile_.tint })}
                />
              ))}
          </div>
        )}
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
          key={page}
          title={title(tile.id)} tint={tile.tint} onClose={closePage}
          wide={page === 'team' || page === 'admin' || page === 'tournament' || page === 'play'}
        >
          {/* The hub Play opens into: three doors that used to each have
              their own front-page tile, now one tap further in. Each button
              zooms the same way a front-page tile does -- growFrom() only
              needs the clicked element's own rect, not that it started life
              in the main grid. Ranked is the hero tile, Vs Friends/Vs Bots
              share one skewed frame beside it -- the same hero+stack shape
              as Play/Tournament+Ladder on the front page, not three equal
              columns (see .playhub-grid in styles.css for why the seam
              needs it just as much in here). */}
          {/* Jared: "there's literally no time to select the deck you want
              to go with" on Ranked, then, after a picker-first detour there
              got tried and un-shipped: "players will find the deck selector
              right above the menu... make sure that whatever they select
              anywhere, it gets saved and remembered everywhere else." This
              is that selector's actual home now -- one screen before any of
              the three doors, so the choice is already made by the time you
              open one. profile/onProfile are the same props every other
              KingdomSwitch on these pages already reads and writes (see
              Kingdoms.tsx's own kshelf, which chooses through this exact
              path too) -- profile is one object lifted to useAuth's own
              patchProfile, so picking a kingdom here, on My Kingdom's shelf,
              or (still) on Vs Bots/Vs Friends updates that same object and
              every screen reading it re-renders with the new choice at
              once, same tab, no round trip needed to see it stick. */}
          {page === 'play' && (() => {
            const ranked = tileById('ranked')
            return (
              <div className="playhub-wrap">
                <KingdomSwitch
                  profile={profile} onProfile={onProfile}
                  className="playhub-kswitch"
                  alwaysShow
                  label={t('kingdom.deckInUse')}
                  onManage={(el) => zoomTo(el, { id: 'team', tint: '#7c3aed' })}
                />
                <div className="playhub-grid">
                  <MenuTile
                    id="ranked" tint={ranked.tint} art={ranked.art} focus={ranked.focus}
                    label={t(TILE_TITLE.ranked)} note={t(TILE_NOTE.ranked)}
                    disabled={busy} artOverride={artOverride('ranked')}
                    onClick={(e) => zoomTo(e.currentTarget, { id: 'ranked', tint: ranked.tint })}
                  />
                  <div className="mtile-stack">
                    {(['friends', 'bot'] as const).map((id) => {
                      const tl = tileById(id)
                      return (
                        <MenuTile
                          key={id}
                          id={id} tint={tl.tint} art={tl.art} focus={tl.focus}
                          label={t(TILE_TITLE[id])} note={t(TILE_NOTE[id])}
                          disabled={busy} artOverride={artOverride(id)}
                          onClick={(e) => zoomTo(e.currentTarget, { id, tint: tl.tint })}
                        />
                      )
                    })}
                  </div>
                </div>
              </div>
            )
          })()}

          {/* Jared: "let's go back to when people clicked on Ranked, they
              directly search for a match" -- the picker-first detour (a
              Find Match button over the deck switch) is gone; landing here
              is the request again, same as Vs Bots/Vs Friends' own doors.
              What actually solved "there's literally no time to select the
              deck" wasn't a page in between, it was moving the switch one
              screen earlier: the Play hub above now carries it, so the
              choice already happened by the time this door opens. */}
          {page === 'ranked' && (
            <div className="modelist is-centered">
              <div className="queuefinder" aria-live="polite">
                <div className="queuefinder-radar" aria-hidden="true">
                  <span className="queuefinder-ring" />
                  <span className="queuefinder-ring" />
                  <span className="queuefinder-ring" />
                  <span className="queuefinder-dot" />
                </div>
                <p className="queuefinder-title">{t('ranked.findingMatch')}</p>
                <p className="queuefinder-sub">{t('ranked.searching', { seconds: elapsed, waiting })}</p>
                <p className="muted tiny queuenote">{t('ranked.fussy')}</p>
                {/* Cancel backs all the way out -- there is nothing left on
                    this page to come back to once you've declined the only
                    thing it does. */}
                <button
                  className="btn ghost"
                  onClick={() => { setSearching(false); leaveRanked(); closePage() }}
                >
                  {t('common.cancel')}
                </button>
              </div>
              {!deckSet && (
                <p className="muted tiny queuenote">
                  {t('ranked.noDeck', {
                    deck: effectiveDeck.join(', ') || t('ranked.defaultFive'),
                  })}
                </p>
              )}
            </div>
          )}

          {/* Item: same two-doors shape as the Friends page just above --
              a solo 1v1 or a full royale table are different enough asks
              that showing every difficulty AND the royale picker on one
              page at once made the page read as one long form rather than
              two short ones. Picking a door reveals only that door's UI.

              Jared, on this same pair: "when you click 1v1, it doesn't
              feel like the calm, sharp, ruthless levels are coming out of
              1v1, but rather just another option... maybe it should have
              some correlation with the level boxes." Vs Friends just below
              keeps the old side-by-side .roommode-pick (its doors only ever
              reveal a button + a code field, never another stack of
              options, so nothing there read as disconnected) -- this pair
              is its own stacked .bcard-row instead: each door is a
              full-width header, and its options grow directly out of its
              own bottom edge, inside the same border, instead of sitting
              in a separate list below both doors. */}
          {page === 'bot' && (
            <div className="modelist is-centered">
              <KingdomSwitch profile={profile} onProfile={onProfile} />

              <div className="bcard-row">
                <div className={`bcard${botMode === '1v1' ? ' is-open' : ''}`}>
                  <button
                    type="button"
                    className="bcard-head"
                    disabled={busy}
                    onClick={() => setBotMode(botMode === '1v1' ? null : '1v1')}
                  >
                    <span className="modecard-name">{t('bot.open1v1')}</span>
                    <span className="modecard-note">{t('bot.open1v1Note')}</span>
                  </button>
                  {botMode === '1v1' && (
                    <div className="bcard-body">
                      {BOT_LEVELS.map((b) => (
                        <button
                          key={b.level}
                          className="modecard"
                          disabled={busy}
                          onClick={() => run(() => createBotMatch(b.level))}
                        >
                          {/* BOT_LEVELS keeps the level number and nothing
                              else that is words: CALM, SHARP and RUTHLESS
                              are names and their notes are sentences, and
                              both belong to the dictionary. */}
                          <span className="modecard-name">{t(`bot.${b.key}`)}</span>
                          <span className="modecard-note">{t(`bot.${b.key}Note`)}</span>
                        </button>
                      ))}
                      <p className="muted tiny queuenote">{t('bot.blurb')}</p>
                    </div>
                  )}
                </div>

                <div className={`bcard${botMode === '4p' ? ' is-open' : ''}`}>
                  <button
                    type="button"
                    className="bcard-head"
                    disabled={busy}
                    onClick={() => setBotMode(botMode === '4p' ? null : '4p')}
                  >
                    <span className="modecard-name">{t('royale.title')}</span>
                    <span className="modecard-note">{t('royale.vsBotsNote')}</span>
                  </button>
                  {botMode === '4p' && (
                    <div className="bcard-body">
                      {/* 0052: a full royale match against 1-3 bots -- one
                          shared difficulty (the seg control) rather than
                          one picker per bot, and a count toggle for how
                          many opponents to face. */}
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
                        className="btn primary big roommode-open"
                        disabled={busy}
                        onClick={() => runRoyale(
                          () => createRoyaleBotMatch(Array(royaleBotCount).fill(royaleBotLevel)),
                        )}
                      >
                        {t('royale.vsBotsStart')}
                      </button>
                    </div>
                  )}
                </div>
              </div>
            </div>
          )}

          {/* Opening a room and joining one used to be two tiles, which made
              the menu ask a question nobody has: whether you are the host. You
              want to play a specific person; one of you sends five letters. */}
          {/* Jared: "also center this one [Vs Friends], and if you open
              any of them, as they get opened, everything is still in the
              center" -- same is-centered class Vs Bots and Ranked already
              carry, so it gets the same horizontal AND vertical treatment
              (see .modelist.is-centered / the .page-body rule above it in
              styles.css) including the live recentring as the room-mode
              picker below reveals its own code form. */}
          {page === 'friends' && (
            <div className="modelist is-centered">
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
                  {/* Jared: "why is W so separated from Streak? put all
                      columns same width" -- table-layout: auto was sizing
                      each column by its own content and handing whatever
                      was left over to whichever column happened to be
                      widest, which read as arbitrary once W, Streak and
                      Cups all shrank to just a few characters. Explicit
                      widths on every column (rank and the four stats fixed,
                      Player the one left to take whatever room remains) is
                      what table-layout: fixed actually needs to hold them
                      still. */}
                  <colgroup>
                    <col style={{ width: '34px' }} />
                    <col />
                    <col style={{ width: '78px' }} />
                    <col style={{ width: '78px' }} />
                    <col style={{ width: '78px' }} />
                    <col style={{ width: '78px' }} />
                  </colgroup>
                  <thead>
                    <tr>
                      {/* "#" stays plain text -- it's this row's position in
                          whatever the sort below currently is, not a stat of
                          its own to sort by (see the LadderSortField comment
                          up top). Every other header is a full-width button;
                          clicking it is what drives sortedLadder. */}
                      <th className="num">#</th>
                      <th>
                        <button
                          type="button"
                          className={`ladder-sortbtn${ladderSort.field === 'player' ? ' is-active' : ''}`}
                          onClick={() => toggleLadderSort('player')}
                        >
                          {t('ladder.player')}
                          {ladderSort.field === 'player' && (
                            <span className="ladder-sortarrow" aria-hidden="true">
                              {ladderSort.dir === 'asc' ? '▲' : '▼'}
                            </span>
                          )}
                        </button>
                      </th>
                      <th className="num">
                        <button
                          type="button"
                          className={`ladder-sortbtn${ladderSort.field === 'rating' ? ' is-active' : ''}`}
                          onClick={() => toggleLadderSort('rating')}
                        >
                          {t('ladder.lp')}
                          {ladderSort.field === 'rating' && (
                            <span className="ladder-sortarrow" aria-hidden="true">
                              {ladderSort.dir === 'asc' ? '▲' : '▼'}
                            </span>
                          )}
                        </button>
                      </th>
                      <th className="num">
                        <button
                          type="button"
                          className={`ladder-sortbtn${ladderSort.field === 'wins' ? ' is-active' : ''}`}
                          onClick={() => toggleLadderSort('wins')}
                        >
                          {t('ladder.w')}
                          {ladderSort.field === 'wins' && (
                            <span className="ladder-sortarrow" aria-hidden="true">
                              {ladderSort.dir === 'asc' ? '▲' : '▼'}
                            </span>
                          )}
                        </button>
                      </th>
                      {/* Jared: losing count is a little sad for a player to see about
                          themselves or anyone else -- kept in the data (r.losses, still
                          fetched, still in admin's view of a profile) and only left out
                          of this table. The loss-streak suffix below still reads
                          ladder.l ("L") for a currently-cold streak -- that key stays. */}
                      <th className="num">
                        <button
                          type="button"
                          className={`ladder-sortbtn${ladderSort.field === 'streak' ? ' is-active' : ''}`}
                          onClick={() => toggleLadderSort('streak')}
                        >
                          {t('ladder.streak')}
                          {ladderSort.field === 'streak' && (
                            <span className="ladder-sortarrow" aria-hidden="true">
                              {ladderSort.dir === 'asc' ? '▲' : '▼'}
                            </span>
                          )}
                        </button>
                      </th>
                      <th className="num" title={t('ladder.cupsNote')}>
                        <button
                          type="button"
                          className={`ladder-sortbtn${ladderSort.field === 'tournaments' ? ' is-active' : ''}`}
                          onClick={() => toggleLadderSort('tournaments')}
                        >
                          {t('ladder.cups')}
                          {ladderSort.field === 'tournaments' && (
                            <span className="ladder-sortarrow" aria-hidden="true">
                              {ladderSort.dir === 'asc' ? '▲' : '▼'}
                            </span>
                          )}
                        </button>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {sortedLadder.map((r, i) => (
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
                        {/* 0082: no more tier column -- the raw rating is the
                            whole story now. */}
                        <td className="num lp">{r.rating}</td>
                        <td className="num">{r.wins}</td>
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
