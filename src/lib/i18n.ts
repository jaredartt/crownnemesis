import { useSyncExternalStore } from 'react'
import { getSettings, useSettings } from './settings'
import en from '../i18n/en.json'
import { getOverride, subscribeOverrideChanges } from './useContentOverrides'

/**
 * The interface, in two languages.
 *
 * The split is the one decided in Phase D and it is worth restating, because
 * the two halves live in different places for different reasons:
 *
 *   UI STRINGS live in this repo, as JSON. They are versioned with the code
 *   that uses them, they cost no database read, and a screen that is late to
 *   load its words is a screen that flashes English at a Spanish reader.
 *
 *   ABILITY TEXT lives in the DATABASE, in cards.ability / cards.ability_es.
 *   A balance tweak rewrites an ability every time, and if that text were in
 *   the repo every tweak would need a deploy -- which defeats the live card
 *   editor the admin panel is meant to become.
 *
 * English is bundled because it is the fallback and the fallback has to be
 * there before anything is fetched. Spanish is a dynamic import: it is a few
 * kilobytes nobody reading English should have to download, and the moment a
 * third language appears that argument only gets stronger.
 *
 * A missing key renders its own name rather than an empty space. An empty
 * space is a layout that looks fine and says nothing; `lobby.play` on screen
 * is a bug reporting itself.
 */

type Dict = Record<string, string>
export type Lang = 'en' | 'es'

const BUNDLED: Record<string, Dict> = { en: en as Dict }
const loaded: Record<string, Dict> = { ...BUNDLED }
const listeners = new Set<() => void>()

/** Bumped whenever a dictionary arrives, so useSyncExternalStore has
 *  something that actually changes to compare. The dictionaries themselves
 *  are stable objects and would otherwise look identical forever. */
let version = 0
const bump = () => { version += 1; listeners.forEach((l) => l()) }

// Since 0046: menu_content_overrides can rewrite any bundled string, and an
// admin editing one over Realtime should be felt the same way a language
// switch is -- every useT() consumer already re-renders on `version`, so an
// override arriving just bumps it too rather than needing its own listener
// set threaded through every screen that calls t(). See
// useContentOverrides.ts for the fetch/cache/Realtime side of this.
subscribeOverrideChanges(bump)

const asLang = (v: unknown): Lang => (v === 'es' ? 'es' : 'en')

export const currentLang = (): Lang =>
  asLang((getSettings() as unknown as { lang?: string }).lang)

/** Fetch a language's strings, once. Safe to call as often as you like. */
const fetching: Record<string, Promise<void> | undefined> = {}
export function loadLang(lang: Lang): Promise<void> {
  if (loaded[lang]) return Promise.resolve()
  if (!fetching[lang]) {
    fetching[lang] = import(`../i18n/${lang}.json`)
      .then((m) => { loaded[lang] = (m.default ?? m) as Dict; bump() })
      .catch((e) => {
        // A language that will not load is a screen in English, which is a
        // great deal better than a screen of nothing.
        console.warn('i18n:', lang, (e as Error).message)
      })
  }
  return fetching[lang]!
}

/**
 * One string.
 *
 * `vars` fills {name}-shaped holes. A hole with no value is left as it is
 * rather than blanked, for the same reason a missing key renders its name:
 * something visibly wrong beats something invisibly wrong.
 *
 * Since 0046: an admin-written row in menu_content_overrides for this exact
 * key wins over the bundled dictionary, in either language -- see
 * useContentOverrides.ts. `key` here is always a literal string written at
 * the call site (the project's own rule against constructing one), so a row
 * keyed by that same literal is guaranteed to mean the sentence it looks
 * like it means, never something a search for the key would miss.
 */
export function translate(lang: Lang, key: string, vars?: Record<string, unknown>): string {
  const s = getOverride(key, lang) ?? loaded[lang]?.[key] ?? loaded.en[key] ?? key
  if (!vars) return s
  return s.replace(/\{(\w+)\}/g, (whole, name) =>
    name in vars ? String(vars[name]) : whole)
}

export function t(key: string, vars?: Record<string, unknown>): string {
  return translate(currentLang(), key, vars)
}

/** The React-facing one: re-renders when the language changes AND when its
 *  dictionary finishes arriving. */
export function useT(): (key: string, vars?: Record<string, unknown>) => string {
  const s = useSettings() as unknown as { lang?: string }
  const lang = asLang(s.lang)
  useSyncExternalStore(
    (l) => { listeners.add(l); return () => listeners.delete(l) },
    () => version,
    () => version,
  )
  if (lang !== 'en') void loadLang(lang)
  return (key, vars) => translate(lang, key, vars)
}

/** Ability text for a card or a unit, in the language in force.
 *
 *  Null Spanish falls back to English on purpose rather than showing nothing:
 *  a card whose translation has not been written yet is still a card somebody
 *  is about to put on a board. */
export function abilityText(
  card: { ability?: string | null; ability_es?: string | null } | null | undefined,
  lang: Lang = currentLang(),
): string {
  if (!card) return ''
  if (lang === 'es') return card.ability_es || card.ability || ''
  return card.ability || ''
}

/** Warm the dictionary for whatever language the settings already say, so the
 *  first paint after sign-in is not English-then-Spanish. */
export function primeLang() {
  const lang = currentLang()
  if (lang !== 'en') void loadLang(lang)
}

/**
 * A unit's class, in the reader's language.
 *
 * Written out one branch at a time rather than as `t('class.' + role)`, and
 * this project has the scar to justify the tedium: `t('settings.theme' + v)`
 * once shipped the literal string `settings.themeSystem` onto a screen,
 * because a constructed key is invisible to a search and invisible to
 * i18ncheck. Five branches is a small price for a key nobody can lose.
 *
 * An unrecognised class falls through to itself, so a card added by hand shows
 * its own word rather than a blank space.
 */
export function useClassName(): (role: string | null | undefined) => string {
  const t = useT()
  return (role) =>
    role === 'royal' ? t('class.royal')
    : role === 'rogue' ? t('class.rogue')
    : role === 'knight' ? t('class.knight')
    : role === 'mage' ? t('class.mage')
    : role === 'flying' ? t('class.flying')
    : (role ?? '')
}
