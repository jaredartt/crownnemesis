import { currentLang } from './i18n'

/**
 * Countries for the profile flag and the Ladder's country filter.
 *
 * Jared: "the most common countries video games usually have... all
 * countries in South America, Africa, Asia and Oceania", and (mid-task) "if
 * drawing them costs a lot of tokens, just use emojis". So a flag here is an
 * EMOJI, built from the two-letter ISO code -- there are no image files,
 * nothing to download, and adding a country is one word in the list below.
 *
 * What is stored is only the code ('ES', 'US'...), in profiles.country
 * (0174). The picture is decided by the player's own device, and the NAME is
 * localised by the browser (Intl.DisplayNames), so there is no table of
 * country names in English or Spanish to keep up to date either.
 *
 * Known limit: Windows has no flag emojis and draws the two letters instead.
 * <Flag> detects that (supportsFlagEmoji) and falls back to a small "ES"
 * badge, so the column is never a row of empty boxes.
 */

/** ISO 3166-1 alpha-2, plus XK (Kosovo, which ISO has never assigned but
 *  every emoji set and every game treats as a country). Antarctica and the
 *  uninhabited outlying islands are left out on purpose: nobody plays from
 *  there. */
export const COUNTRY_CODES: readonly string[] = (
  'AD AE AF AG AI AL AM AO AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BW BY BZ '
  + 'CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FK FM '
  + 'FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GT GU GW GY HK HN HR HT HU ID IE IL IM IN IQ IR IS IT JE '
  + 'JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM '
  + 'MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN '
  + 'PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TG '
  + 'TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW'
).split(' ')

/** The Ladder filter's "everyone" value. Not a country code, so it can never
 *  collide with one. */
export const WORLD = 'WORLD'
/** There is no universal country flag, so "World" gets a globe. */
export const WORLD_EMOJI = '\u{1F30D}'

export const isCountryCode = (v: unknown): v is string =>
  typeof v === 'string' && /^[A-Z]{2}$/.test(v)

/** 'ES' -> the Spanish flag: each letter becomes its regional-indicator
 *  symbol, and two of those side by side render as a flag. */
export function flagEmoji(code: string): string {
  return [...code.toUpperCase()]
    .map((c) => String.fromCodePoint(0x1f1e6 + c.charCodeAt(0) - 65))
    .join('')
}

const namers: Record<string, Intl.DisplayNames | null> = {}
/** The country's name in the interface language ('Spain' / 'España'). Falls
 *  back to the bare code if the browser cannot name it. */
export function countryName(code: string, lang: string = currentLang()): string {
  try {
    if (!(lang in namers)) {
      namers[lang] = typeof Intl.DisplayNames === 'function'
        ? new Intl.DisplayNames([lang], { type: 'region' })
        : null
    }
    return namers[lang]?.of(code.toUpperCase()) ?? code
  } catch {
    return code
  }
}

let flagSupport: boolean | null = null
/** Does this device draw a flag emoji as ONE picture? On Windows the two
 *  regional-indicator letters render side by side as plain letters, so the
 *  pair measures about as wide as its parts; a real flag is a single glyph,
 *  clearly narrower than the two letters together. */
export function supportsFlagEmoji(): boolean {
  if (flagSupport != null) return flagSupport
  try {
    const ctx = document.createElement('canvas').getContext('2d')
    if (!ctx) return (flagSupport = true)
    ctx.font = '32px sans-serif'
    const whole = ctx.measureText(flagEmoji('US')).width
    const parts = ctx.measureText(flagEmoji('U')).width + ctx.measureText(flagEmoji('S')).width
    flagSupport = whole < parts * 0.85
  } catch {
    flagSupport = true
  }
  return flagSupport
}
