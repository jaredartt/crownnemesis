import type { CSSProperties } from 'react'
import { useT } from '../lib/i18n'

/**
 * The turn's goes -- one big bar per activation -- shown in the box under the
 * units (Jared: "that's where the new big 2 actions will show").
 *
 * Each bar is a go. The one the clock is running for is `is-live`: its fill is
 * the go's own clock, draining with the timer, and its caption counts the
 * seconds. Running the clock out (or using the go) spends it: the bar flashes
 * and settles grey. Same rhomboid as everything else that counts something.
 */
export function GoPips({
  cap, spent, live, pct, seconds, urgent, mine,
}: {
  /** activations this turn (1 on the opening turn and in Battle Royale) */
  cap: number
  /** activations already counted (state.acts, clamped to cap) */
  spent: number
  /** index of the go the clock is running for, or -1 */
  live: number
  /** 0..1 of that go's clock still left */
  pct: number
  /** whole seconds left on that clock, or null */
  seconds: number | null
  urgent: boolean
  /** it is the viewer's own turn (the live go breathes) */
  mine: boolean
}) {
  const t = useT()
  const left = cap - spent
  return (
    <div
      className={`goes${urgent ? ' is-urgent' : ''}${mine ? ' is-mine' : ''}`}
      role="img"
      aria-label={t('match.goesLabel', { left, cap, word: t(cap === 1 ? 'match.go' : 'match.goes') })}
      title={t('match.goesLeft', { left, cap })}
    >
      {Array.from({ length: cap }, (_, i) => {
        const isLive = i === live
        const state = isLive ? 'is-live' : i < spent ? 'is-used' : ''
        return (
          <div key={i} className={`go-cell ${state}`}>
            <span
              className={`go ${state}`}
              style={isLive ? ({ '--p': pct } as CSSProperties) : undefined}
            />
            <span className="go-cap">
              {t('match.goN', { n: i + 1 })}
              {isLive && seconds !== null ? ` · ${seconds}s` : ''}
            </span>
          </div>
        )
      })}
    </div>
  )
}
