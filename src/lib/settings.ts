/**
 * Sound, motion and the theme.
 *
 * These used to be three numbers in localStorage, and the old comment here
 * defended that: nothing another device needs to know, and a volume slider
 * that waits for a round trip feels broken. Half of that still holds. The
 * other half stopped holding the moment a THEME joined them -- signing in on a
 * phone and getting a white screen because the preference stayed on the laptop
 * is not a cache miss, it is the setting not working.
 *
 * So the account is the truth and localStorage is the cache in front of it.
 * The slider still moves instantly, the page still paints the right colours
 * before anything has been fetched, and the account is what makes it true on
 * the next device. Writes go local-first and are pushed up debounced; the
 * account's copy wins when it arrives.
 *
 * A module-level store rather than context, because the settings panel, the
 * sound player, both transitions and the cinematic all read it, and most of
 * those are not React components.
 */
import { useSyncExternalStore } from 'react'
import { pushSettings } from './api'

export type Theme = 'system' | 'light' | 'dark'
export type Lang = 'en' | 'es'

/** How much of a fight you want to watch. 'full' is the takeover Phase C
 *  built, 'quick' is the same beats told faster with no squaring-up, and
 *  'off' leaves the board's own lunges and numbers and never takes the screen.
 *
 *  THE CLOCK IS THE SAME WHICHEVER YOU PICK. 0021 pushes the turn deadline by
 *  the full cinematic's length regardless, so turning this down hands you that
 *  time back as thinking time -- which is exactly what the Skip button has
 *  done since Phase C shipped. Making the server compute a different deadline
 *  per side would leak a preference into a shared clock to close a hole that
 *  is already open on purpose. */
export type CineMode = 'full' | 'quick' | 'off'

export interface Settings {
  /** 0..1 */
  sfx: number
  /** 0..1 */
  music: number
  /** Menu transitions, and the cinematic's drifting. The board's own
   *  animations are how you read a match, so they are never touched. */
  reduceMotion: boolean
  /** 'system' follows the operating system and is the default. The other two
   *  are a decision, and a decision outranks the operating system. */
  theme: Theme
  /** The interface's language. NOT the browser's: somebody who reads English
   *  on a Spanish laptop has said so by choosing, and there is no 'system'
   *  here because a half-translated screen is worse than a decision. */
  lang: Lang
  /** See CineMode. */
  cine: CineMode
  /** Has this account made it through (or skipped) the first-time
   *  tutorial? False for a brand new account (settings starts as {}, so
   *  this key is simply absent -- clean() below reads that as false); a
   *  one-time migration backfilled every account that existed before this
   *  landed to true, so the tutorial only ever appears for real newcomers.
   *  "Replay tutorial" in Settings flips this back to false on purpose. */
  tutorialSeen: boolean
}

const KEY = 'cn.settings'
const DEFAULTS: Settings = {
  sfx: 0.5, music: 0.4, reduceMotion: false, theme: 'system', lang: 'en',
  cine: 'full', tutorialSeen: false,
}

const clamp = (n: number) => Math.max(0, Math.min(1, Number(n) || 0))
const asTheme = (v: unknown): Theme =>
  v === 'light' || v === 'dark' || v === 'system' ? v : 'system'
const asLang = (v: unknown): Lang => (v === 'es' ? 'es' : 'en')

/** Mirrors cn_clean_settings() in 0022. The server cleans what it is given; so
 *  does this, because a cache can be edited by hand just as a column can. */
function clean(v: Partial<Settings> | null | undefined): Settings {
  if (!v || typeof v !== 'object') return { ...DEFAULTS }
  return {
    sfx: clamp(v.sfx ?? DEFAULTS.sfx),
    music: clamp(v.music ?? DEFAULTS.music),
    reduceMotion: Boolean(v.reduceMotion),
    theme: asTheme(v.theme),
    lang: asLang(v.lang),
    cine: asCine(v.cine),
    tutorialSeen: Boolean(v.tutorialSeen),
  }
}

/** Unlike the theme, an unrecognised value falls back to the DEFAULT rather
 *  than being kept -- and 0026 drops it on the server for the mirror-image
 *  reason. Either way nobody ends up with a preference that means nothing. */
const asCine = (v: unknown): CineMode =>
  (v === 'quick' || v === 'off' || v === 'full') ? v : DEFAULTS.cine

function read(): Settings {
  try {
    const raw = localStorage.getItem(KEY)
    return raw ? clean(JSON.parse(raw) as Partial<Settings>) : { ...DEFAULTS }
  } catch {
    // A private window, blocked site data, a browser that throws on read --
    // none of which is a reason to fail to start.
    return { ...DEFAULTS }
  }
}

let state = read()
const listeners = new Set<() => void>()

/** Whether there is an account to write to. False while signed out, when
 *  set_settings would only ever answer 'not signed in'. */
let linked = false

const dark = () =>
  typeof matchMedia !== 'undefined' && matchMedia('(prefers-color-scheme: dark)').matches

/** The theme actually in force, with 'system' resolved. */
export function resolvedTheme(): 'light' | 'dark' {
  if (state.theme === 'dark') return 'dark'
  if (state.theme === 'light') return 'light'
  return dark() ? 'dark' : 'light'
}

function publish() {
  const root = document.documentElement
  root.dataset.reduceMotion = state.reduceMotion ? '1' : ''
  // Always stamped with the RESOLVED theme rather than left for a media query
  // to answer. The stylesheet then has one question to ask instead of three,
  // and 'system' stops being a third state every rule has to think about.
  root.dataset.theme = resolvedTheme()
  // So a screen reader, and the browser's own hyphenation and quotes, agree
  // with what is actually written on the page.
  root.lang = state.lang
  // So the browser's own furniture -- scrollbars, form controls, the flash of
  // background before paint -- agrees with the page.
  root.style.colorScheme = resolvedTheme()
  listeners.forEach((l) => l())
}
publish()

// Following the system means following it as it changes, not only as it was
// when the tab opened.
if (typeof matchMedia !== 'undefined') {
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (state.theme === 'system') publish()
  })
}

function save() {
  try { localStorage.setItem(KEY, JSON.stringify(state)) } catch { /* not fatal */ }
}

/* ---------------------------------------------------------------------------
 * Pushing up.
 *
 * Debounced and coalesced, because the thing most likely to change a setting
 * is a finger on a volume slider, and that is thirty changes a second. What
 * goes up is the accumulated PATCH rather than the whole blob -- the server
 * merges it, so two devices editing different settings do not overwrite each
 * other, and a key this build has never heard of is not erased by a build that
 * does not know to send it.
 * ------------------------------------------------------------------------- */
let pending: Partial<Settings> = {}
let timer: ReturnType<typeof setTimeout> | null = null
const PUSH_MS = 400

function flush() {
  timer = null
  const patch = pending
  pending = {}
  if (!linked || Object.keys(patch).length === 0) return
  // Fire and forget. A settings write that fails is a setting that is right
  // here and stale elsewhere, which is worth a console line and not worth a
  // dialog in front of somebody who is trying to play a game.
  pushSettings(patch).catch((e) => console.warn('settings:', (e as Error).message))
}

export function setSettings(patch: Partial<Settings>) {
  state = clean({ ...state, ...patch })
  save()
  publish()
  pending = { ...pending, ...patch }
  if (!timer) timer = setTimeout(flush, PUSH_MS)
}

export const getSettings = () => state

/**
 * The account's copy has arrived.
 *
 * The account wins for every key it actually carries, and the local cache
 * keeps the rest -- which is also the migration path for anybody who had
 * settings in this browser before the column existed: whatever the account is
 * missing gets pushed up once, and from then on the two agree.
 */
export function hydrate(remote: unknown) {
  linked = true
  const r = (remote && typeof remote === 'object' ? remote : {}) as Partial<Settings>
  const missing: Partial<Settings> = {}
  for (const k of ['sfx', 'music', 'reduceMotion', 'theme', 'lang'] as const) {
    if (!(k in r)) (missing as Record<string, unknown>)[k] = state[k]
  }
  state = clean({ ...state, ...r })
  save()
  publish()
  if (Object.keys(missing).length) {
    pending = { ...missing, ...pending }
    if (!timer) timer = setTimeout(flush, PUSH_MS)
  }
}

/** Signed out. The settings stay -- they are still this browser's -- but there
 *  is nothing to write them to until somebody signs in again. */
export function unlink() {
  linked = false
  pending = {}
  if (timer) { clearTimeout(timer); timer = null }
}

export function useSettings(): Settings {
  return useSyncExternalStore(
    (l) => { listeners.add(l); return () => listeners.delete(l) },
    () => state,
    () => state,
  )
}

/** The setting OR the operating system's. Either one means: not this. */
export function lessMotion(): boolean {
  return (
    state.reduceMotion ||
    (typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches)
  )
}
