/**
 * Look & feel dials (0220), set from Admin Mode -> Look & feel and read by every
 * client. Each is a percentage of today's look: 100 = unchanged.
 *
 *  - fight_speed:      the fight scene's clock (Board.tsx retimes each cinematic).
 *  - ui_speed:         menu and transition animations. A CSS variable, --ui-speed,
 *                      divides those animations' durations (styles.css); the screen
 *                      wipe's timers (Wipe.tsx) read uiRate() too.
 *  - hp_drain_speed:   the HP bar's change animation and the HP number's count,
 *                      CSS variable --hp-speed plus hpRate().
 *  - hp_bar_thickness: CSS variable --hp-thick multiplies the bar's height.
 *
 * applyLookFeel() is called whenever the settings row loads or changes
 * (useAppSettings.ts), and the admin tab calls it too, with unsaved values, to
 * preview a change on the screen you are looking at.
 */
import type { AppSettings } from './types'

export interface LookFeel { fight_speed: number; ui_speed: number; hp_drain_speed: number; hp_bar_thickness: number }
export const LOOK_DEFAULTS: LookFeel = { fight_speed: 100, ui_speed: 100, hp_drain_speed: 100, hp_bar_thickness: 100 }

let fight = 1, ui = 1, hp = 1

export const fightRate = () => fight
export const uiRate = () => ui
export const hpRate = () => hp

export function applyLookFeel(s: Partial<AppSettings> | LookFeel) {
  const v = { ...LOOK_DEFAULTS, ...Object.fromEntries(Object.entries(s).filter(([, x]) => typeof x === 'number')) } as LookFeel
  fight = v.fight_speed / 100
  ui = v.ui_speed / 100
  hp = v.hp_drain_speed / 100
  if (typeof document === 'undefined') return
  const root = document.documentElement.style
  root.setProperty('--ui-speed', String(ui))
  root.setProperty('--hp-speed', String(hp))
  root.setProperty('--hp-thick', String(v.hp_bar_thickness / 100))
}
