import { useMemo } from 'react'
import { useT } from '../lib/i18n'

/** One turn's read of who was ahead, scored relative to the viewer -- see
 *  the capture effect in Match.tsx. Positive means the viewer was ahead
 *  that turn, negative means the opponent was, both on a -100..100 scale
 *  built from surviving HP (against each side's OWN starting total, so a
 *  small army that is still full-health does not read as "losing") minus a
 *  few points per unit currently burning, poisoned or stunned. */
export interface AdvantagePoint {
  turn: number
  edge: number
}

/**
 * "Who had the edge, and when" -- one diverging line, not two series. There
 * is only ever one question (were you ahead, or were they), so a second
 * colour for the mirror image of the same number would be decoration, not
 * information: above the zero line is you, in the app's own --you blue (the
 * same colour tile-mine/kswitch already use for "this one is yours"); below
 * it is them, in --danger, the same red every resign/leave confirmation
 * already uses for "you are about to lose something". Thin marks, a
 * recessive zero baseline, and exactly one label -- the single biggest
 * swing -- rather than a number on every point.
 */
export function AdvantageChart({ points, youName, themName }: {
  points: AdvantagePoint[]
  youName: string
  themName: string
}) {
  const t = useT()
  const W = 560
  const H = 108
  const PAD_X = 4
  const PAD_Y = 12

  const chart = useMemo(() => {
    const n = points.length
    if (n === 0) return null
    const xOf = (i: number) => (n <= 1 ? W / 2 : PAD_X + (i * (W - PAD_X * 2)) / (n - 1))
    const maxAbs = Math.max(12, ...points.map((p) => Math.abs(p.edge)))
    const zeroY = H / 2
    const yOf = (edge: number) => zeroY - (edge / maxAbs) * (zeroY - PAD_Y)

    const areaPath = (side: 'above' | 'below') => {
      const xs = points.map((_, i) => xOf(i))
      const ys = points.map((p) => yOf(side === 'above' ? Math.max(0, p.edge) : Math.min(0, p.edge)))
      return [
        `M ${xs[0]} ${zeroY}`,
        ...xs.map((x, i) => `L ${x} ${ys[i]}`),
        `L ${xs[xs.length - 1]} ${zeroY}`,
        'Z',
      ].join(' ')
    }

    let peak = points[0]
    for (const p of points) if (Math.abs(p.edge) > Math.abs(peak.edge)) peak = p
    const peakIdx = points.indexOf(peak)

    return {
      pathAbove: areaPath('above'),
      pathBelow: areaPath('below'),
      zeroY,
      peak,
      peakX: xOf(peakIdx),
      peakY: yOf(peak.edge),
    }
  }, [points])

  if (!chart) return null
  const { pathAbove, pathBelow, zeroY, peak, peakX, peakY } = chart
  const peakIsYou = peak.edge >= 0
  const peakAmount = Math.round(Math.abs(peak.edge))

  return (
    <div className="advchart">
      <div className="advchart-head">
        <span className="advchart-title">{t('match.advantageTitle')}</span>
        <span className="advchart-legend">
          <span className="advchart-swatch is-you" aria-hidden="true" />{youName}
          <span className="advchart-swatch is-them" aria-hidden="true" />{themName}
        </span>
      </div>
      <svg
        viewBox={`0 0 ${W} ${H}`} width="100%" height={H} preserveAspectRatio="none"
        role="img" aria-label={t('match.advantageTitle')}
      >
        <line x1={PAD_X} y1={zeroY} x2={W - PAD_X} y2={zeroY} className="advchart-zero" />
        <path d={pathAbove} className="advchart-fill is-you" />
        <path d={pathBelow} className="advchart-fill is-them" />
        {peakAmount >= 4 && (
          <circle cx={peakX} cy={peakY} r={3.5} className={`advchart-peak ${peakIsYou ? 'is-you' : 'is-them'}`} />
        )}
      </svg>
      {peakAmount >= 4 && (
        <p className="advchart-note">
          {t('match.biggestLead', {
            name: peakIsYou ? youName : themName, amount: peakAmount, turn: peak.turn,
          })}
        </p>
      )}
    </div>
  )
}
