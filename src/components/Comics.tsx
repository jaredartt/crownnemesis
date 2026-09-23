import { useState } from 'react'
import { useT } from '../lib/i18n'
import { useComicChapters, useComicChaptersLoaded } from '../lib/useComics'
import type { ComicChapterWithPages } from '../lib/types'

/**
 * The comics, read the way a webcomic is read: pick a chapter, then scroll.
 *
 * Used to read a static public/comics/index.json -- adding a chapter meant
 * dropping images into the repo and deploying. Since 0080_comics.sql the
 * pages live in Supabase Storage and the chapter list in the database, so
 * Admin Mode's Comics tab (AdminComics.tsx) can publish a new chapter with
 * no deploy at all. This component's own job didn't change: pick a
 * chapter, then scroll it top to bottom.
 */
export function Comics() {
  const t = useT()
  const chapters = useComicChapters()
  const loaded = useComicChaptersLoaded()
  const [open, setOpen] = useState<ComicChapterWithPages | null>(null)

  if (!loaded) return <p className="muted">{t('comics.loading')}</p>

  if (open) {
    return (
      <div className="comic">
        <button className="linkbtn comic-back" onClick={() => setOpen(null)}>
          {t('comics.allChapters')}
        </button>
        <h3 className="comic-title">{open.title}</h3>
        {open.note && <p className="muted comic-note">{open.note}</p>}
        <div className="comic-pages">
          {open.pages.map((p, i) => (
            <img
              key={p.id}
              src={p.url}
              alt={t('comics.pageAlt', { title: open.title, n: i + 1 })}
              loading={i < 2 ? 'eager' : 'lazy'}
            />
          ))}
        </div>
        <button className="btn ghost comic-foot" onClick={() => setOpen(null)}>
          {t('comics.backToChapters')}
        </button>
      </div>
    )
  }

  if (chapters.length === 0) {
    return (
      <p className="muted">
        Nothing here yet. The first chapter goes up when it is drawn.
      </p>
    )
  }

  return (
    <ul className="chapters">
      {chapters.map((c) => {
        const cover = c.thumbnail ?? c.pages[0]?.url
        return (
          <li key={c.id}>
            <button className="chapter" onClick={() => setOpen(c)}>
              {cover && (
                <span
                  className="chapter-cover"
                  style={{ backgroundImage: `url(${cover})` }}
                  aria-hidden="true"
                />
              )}
              <span className="chapter-body">
                <b>{c.title}</b>
                {c.note && <em>{c.note}</em>}
                <i>{c.pages.length} {c.pages.length === 1 ? 'page' : 'pages'}</i>
              </span>
            </button>
          </li>
        )
      })}
    </ul>
  )
}
