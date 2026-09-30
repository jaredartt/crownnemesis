import { useT } from '../lib/i18n'

/**
 * "ACTIONS LEFT:" and one block per activation, in the box under the units
 * (Jared). They are just blocks -- the turn has ONE 30-second clock (the bar
 * above the board) and nothing here counts time. A block is blue while its go
 * is still available and goes grey (with a small flash) once it is used. On the
 * opponent's turn the available blocks are grey too, for the player watching:
 * those goes are not theirs to take.
 */
export function GoPips({
  cap, spent, theirs,
}: {
  /** activations this turn (1 on the opening turn and in Battle Royale) */
  cap: number
  /** activations already counted (state.acts, clamped to cap) */
  spent: number
  /** the viewer is a player and it is the OTHER player's turn */
  theirs: boolean
}) {
  const t = useT()
  const left = cap - spent
  return (
    <div
      className={`goes${theirs ? ' is-theirs' : ''}`}
      role="img"
      aria-label={t('match.goesLabel', { left, cap, word: t(cap === 1 ? 'match.go' : 'match.goes') })}
      title={t('match.goesLeft', { left, cap })}
    >
      <span className="goes-label">{t('match.actionsLeft')}</span>
      {Array.from({ length: cap }, (_, i) => (
        <span key={i} className={`go${i < spent ? ' is-used' : ''}`} />
      ))}
    </div>
  )
}
