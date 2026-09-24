import { artUrl, faceUrl } from '../lib/art'
import { useCardsBySlug } from '../lib/useCards'

/**
 * A face in a circle. The token the board uses, cropped to a round window.
 *
 * `slug` rather than a URL, so the column stays a foreign key in spirit and a
 * character whose art is redrawn is redrawn everywhere at once.
 *
 * Jared: "when I upload a photo via the admin view, it doesn't render the
 * icons down there when battling someone." Root cause was this component
 * guessing a card's picture lives at `cards/<slug>.webp` in the repository --
 * true for every card shipped with the game, but not for one added later
 * through Admin Mode -> Cards, whose art AdminCards.tsx uploads to Supabase
 * Storage instead (a different domain entirely) and which can be any image
 * type, not only .webp. That guess is right there in `cards.art_url` already
 * -- every other screen that draws a card (Board.tsx, BigCard.tsx, ...) reads
 * it rather than reconstructing it, so this one does too now, through the
 * same cached roster (useCardsBySlug) everything else shares. The slug-guess
 * stays as a fallback for the moment a card's own fetch hasn't landed yet.
 *
 * And, same as Board.tsx's own Portrait: a card's face is a hand-uploaded
 * crop that can simply be missing (only the full art was ever given one) --
 * onError falls back to the full picture instead of leaving a broken image
 * in a spot that used to hold somebody's face.
 */
export function Avatar({
  slug, name, size = 32, className = '',
}: {
  slug: string | null | undefined
  name: string
  size?: number
  className?: string
}) {
  const cards = useCardsBySlug()
  const art = (slug && cards.get(slug)?.art_url) || (slug ? `cards/${slug}.webp` : null)
  const src = art ? faceUrl(art) : null
  return (
    <span
      className={`avatar ${className}`.trim()}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      {src ? (
        <img
          src={src}
          alt=""
          onError={(e) => {
            const el = e.currentTarget
            const full = artUrl(art)
            if (full && el.src !== full) el.src = full
          }}
        />
      ) : (
        <i>{name.slice(0, 1).toUpperCase()}</i>
      )}
    </span>
  )
}
