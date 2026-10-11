import type { Card } from '../lib/types'
import { faceUrl } from '../lib/art'
import { useHpNumWidth } from './HpChunk'

/**
 * The card's token exactly as the board draws it: the same .unit / .unit-face
 * / .unit-hpbar / .unit-hpnum markup and CSS (blue "yours" bar, the rhomboid
 * with the number, the black fade behind it), at a full bar, so the HP shows
 * the way a player sees it at the start of a match. Click it to replace the
 * token picture.
 */
export function CardToken({ card, onPick }: { card: Card; onPick: () => void }) {
  const numRef = useHpNumWidth()
  const src = faceUrl(card.art_url)
  return (
    <div className="cardtoken">
      <div
        className={`unit unit-host is-yours${card.role ? ` role-${card.role}` : ''}`}
        style={{ '--accent': card.accent || '#888888' } as React.CSSProperties}
        onClick={onPick} title="Click to change the token picture" role="button"
      >
        <div className="unit-face">
          <div className="unit-art">
            {src
              ? <img src={src} alt="" onError={(e) => { e.currentTarget.style.visibility = 'hidden' }} />
              : <span className="unit-initial">{(card.name || '?')[0]}</span>}
          </div>
          <div className="unit-hpbar">
            <span className="unit-hpfill" style={{ width: '100%' }} />
          </div>
          <b className="unit-hpnum" ref={numRef}>{card.hp}</b>
        </div>
      </div>
      <span className="muted tiny">Token — as it looks on the board</span>
    </div>
  )
}
