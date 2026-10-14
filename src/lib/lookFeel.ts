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
 *  - rhomb_roundness:  how round the corners of the menu rhomboids are, 0 (sharp, as it
 *                      always was) to 100 (20px). CSS variable --rhomb-r; every rhomboid
 *                      reads it with a 0 fallback, so 0 is a complete undo.
 *  - motion_blur:      how long the motion-blur trail behind a moving card is (0 off,
 *                      1 standard, 2 double): blurRate(), read by lib/motionBlur.ts.
 *
 * applyLookFeel() is called whenever the settings row loads or changes
 * (useAppSettings.ts), and the admin tab calls it too, with unsaved values, to
 * preview a change on the screen you are looking at.
 */
import type { AppSettings } from './types'

export interface LookFeel { fight_speed: number; ui_speed: number; hp_drain_speed: number; hp_bar_thickness: number; motion_blur: number; rhomb_roundness: number }
export const LOOK_DEFAULTS: LookFeel = { fight_speed: 100, ui_speed: 100, hp_drain_speed: 100, hp_bar_thickness: 100, motion_blur: 100, rhomb_roundness: 50 }

let fight = 1, ui = 1, hp = 1, blur = 1

export const fightRate = () => fight
export const uiRate = () => ui
export const hpRate = () => hp
/** 0 = off, 1 = standard, 2 = double. */
export const blurRate = () => blur

export function applyLookFeel(s: Partial<AppSettings> | LookFeel) {
  const v = { ...LOOK_DEFAULTS, ...Object.fromEntries(Object.entries(s).filter(([, x]) => typeof x === 'number')) } as LookFeel
  fight = v.fight_speed / 100
  ui = v.ui_speed / 100
  hp = v.hp_drain_speed / 100
  blur = v.motion_blur / 100
  if (typeof document === 'undefined') return
  const root = document.documentElement.style
  root.setProperty('--ui-speed', String(ui))
  root.setProperty('--hp-speed', String(hp))
  root.setProperty('--hp-thick', String(v.hp_bar_thickness / 100))
  root.setProperty('--mb-set', String(blur))
  root.setProperty('--rhomb-r', `${(v.rhomb_roundness * 0.2).toFixed(1)}px`)
}
