import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useComicChapters } from '../lib/useComics'
import type { ComicChapterWithPages, ComicPage } from '../lib/types'

/**
 * The Comics tab, since 0080_comics.sql. A chapter is a title, a note, an
 * optional cover thumbnail, and a stack of page images read top to bottom
 * -- a down-scrolling webtoon, same as Comics.tsx (the reader) already
 * rendered when the pages were static files. This is the write side that
 * never existed: upload the pages, reorder them, retitle the chapter,
 * write its note, give it a thumbnail.
 *
 * Same master/detail shape as AdminStructures.tsx -- a list on the left,
 * an explicit form on the right -- and the same up/down `move()` swap
 * AdminMusic.tsx uses for its playlists, applied twice here: once to order
 * the chapters themselves, once (inside the open chapter) to order its
 * pages. Every write is an ordinary table/storage write, held to
 * cn_is_super_admin() by 0080's own RLS -- nothing here re-checks who is
 * allowed, the same reasoning AdminMusic.tsx's own header gives.
 */
export function AdminComics() {
  const chapters = useComicChapters()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)

  const sorted = chapters.slice().sort((a, b) => a.sort - b.sort)
  const selected = sorted.find((c) => c.id === selectedId) ?? null

  function flash(msg: string) {
    setNote(msg)
    setTimeout(() => setNote((n) => (n === msg ? null : n)), 2000)
  }

  async function createChapter() {
    setBusy(true); setErr(null)
    const nextSort = sorted.length ? Math.max(...sorted.map((c) => c.sort)) + 1 : 0
    const { data, error } = await supabase
      .from('comic_chapters')
      .insert({ title: 'New chapter', note: '', sort: nextSort })
      .select('*')
      .single()
    setBusy(false)
    if (error || !data) { setErr(error?.message ?? 'could not create the chapter'); return }
    setSelectedId((data as ComicChapterWithPages).id)
  }

  async function saveField(id: string, patch: { title: string } | { note: string }) {
    setErr(null)
    const { error } = await supabase.from('comic_chapters').update(patch).eq('id', id)
    if (error) { setErr(error.message); return }
    flash('Saved.')
  }

  async function moveChapter(c: ComicChapterWithPages, dir: -1 | 1) {
    const idx = sorted.findIndex((x) => x.id === c.id)
    const swap = sorted[idx + dir]
    if (!swap) return
    setBusy(true); setErr(null)
    const { error: e1 } = await supabase.from('comic_chapters').update({ sort: swap.sort }).eq('id', c.id)
    const { error: e2 } = await supabase.from('comic_chapters').update({ sort: c.sort }).eq('id', swap.id)
    setBusy(false)
    if (e1 || e2) setErr((e1 ?? e2)?.message ?? 'could not reorder')
  }

  async function deleteChapter(id: string) {
    setBusy(true); setErr(null)
    const { error } = await supabase.from('comic_chapters').delete().eq('id', id)
    setBusy(false)
    setConfirmDelete(null)
    if (error) { setErr(error.message); return }
    if (selectedId === id) setSelectedId(null)
    flash('Chapter deleted.')
  }

  async function uploadThumbnail(chapter: ComicChapterWithPages, file: File) {
    setBusy(true); setErr(null)
    const ext = file.name.split('.').pop() || 'webp'
    const path = `${chapter.id}/thumb-${Date.now().toString(36)}.${ext}`
    const { error: upErr } = await supabase.storage.from('comics')
      .upload(path, file, { contentType: file.type || undefined })
    if (upErr) { setBusy(false); setErr(upErr.message); return }
    const { data } = supabase.storage.from('comics').getPublicUrl(path)
    const { error } = await supabase.from('comic_chapters')
      .update({ thumbnail: data.publicUrl }).eq('id', chapter.id)
    setBusy(false)
    if (error) setErr(error.message)
  }

  async function removeThumbnail(chapter: ComicChapterWithPages) {
    setErr(null)
    const { error } = await supabase.from('comic_chapters').update({ thumbnail: null }).eq('id', chapter.id)
    if (error) setErr(error.message)
  }

  async function uploadPages(chapter: ComicChapterWithPages, files: File[]) {
    setBusy(true); setErr(null)
    let nextSort = chapter.pages.length ? Math.max(...chapter.pages.map((p) => p.sort)) + 1 : 0
    for (const file of files) {
      const ext = file.name.split('.').pop() || 'webp'
      const path = `${chapter.id}/page-${Date.now().toString(36)}-${nextSort}.${ext}`
      const { error: upErr } = await supabase.storage.from('comics')
        .upload(path, file, { contentType: file.type || undefined })
      if (upErr) { setErr(upErr.message); continue }
      const { data } = supabase.storage.from('comics').getPublicUrl(path)
      const { error } = await supabase.from('comic_pages')
        .insert({ chapter_id: chapter.id, url: data.publicUrl, sort: nextSort })
      if (error) { setErr(error.message); continue }
      nextSort += 1
    }
    setBusy(false)
  }

  async function movePage(chapter: ComicChapterWithPages, p: ComicPage, dir: -1 | 1) {
    const idx = chapter.pages.findIndex((x) => x.id === p.id)
    const swap = chapter.pages[idx + dir]
    if (!swap) return
    setBusy(true); setErr(null)
    const { error: e1 } = await supabase.from('comic_pages').update({ sort: swap.sort }).eq('id', p.id)
    const { error: e2 } = await supabase.from('comic_pages').update({ sort: p.sort }).eq('id', swap.id)
    setBusy(false)
    if (e1 || e2) setErr((e1 ?? e2)?.message ?? 'could not reorder')
  }

  async function deletePage(p: ComicPage) {
    setErr(null)
    const { error } = await supabase.from('comic_pages').delete().eq('id', p.id)
    if (error) setErr(error.message)
  }

  return (
    <div className="admin">
      <div className="admin-list">
        {sorted.map((c, i) => (
          <div
            key={c.id}
            role="button" tabIndex={0}
            className={`admin-row admin-comicrow${c.id === selectedId ? ' is-open' : ''}`}
            onClick={() => setSelectedId(c.id)}
            onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') setSelectedId(c.id) }}
          >
            <span className="admin-comicacts">
              <button
                type="button" className="btn tiny ghost" disabled={busy || i === 0}
                onClick={(e) => { e.stopPropagation(); void moveChapter(c, -1) }} aria-label="Move earlier"
              >
                ↑
              </button>
              <button
                type="button" className="btn tiny ghost" disabled={busy || i === sorted.length - 1}
                onClick={(e) => { e.stopPropagation(); void moveChapter(c, 1) }} aria-label="Move later"
              >
                ↓
              </button>
            </span>
            <span className="admin-rowname">{c.title || '(untitled)'}</span>
            <span className="admin-tag">{c.pages.length}p</span>
          </div>
        ))}
        {sorted.length === 0 && <p className="muted tiny">No chapters yet.</p>}
        <button type="button" className="btn ghost" disabled={busy} onClick={() => void createChapter()}>
          + New chapter
        </button>
      </div>

      {selected ? (
        <div className="admin-form">
          <div className="admin-grid">
            <label className="admin-wide">
              <span>Title</span>
              <input
                key={`${selected.id}-title-${selected.title}`}
                type="text" defaultValue={selected.title}
                onBlur={(e) => {
                  const v = e.target.value.trim()
                  if (v !== selected.title) void saveField(selected.id, { title: v })
                }}
              />
            </label>
            <label className="admin-wide">
              <span>Description (shown under the title, in the chapter list)</span>
              <textarea
                key={`${selected.id}-note-${selected.note}`}
                defaultValue={selected.note} rows={2}
                onBlur={(e) => {
                  const v = e.target.value.trim()
                  if (v !== selected.note) void saveField(selected.id, { note: v })
                }}
              />
            </label>
          </div>

          <div className="admin-arts admin-wide">
            <figure>
              <img src={selected.thumbnail ?? selected.pages[0]?.url ?? ''} alt="" />
              <figcaption>Thumbnail (optional — falls back to the first page)</figcaption>
              <input
                type="file" accept="image/*"
                onChange={(e) => { const f = e.target.files?.[0]; if (f) void uploadThumbnail(selected, f); e.target.value = '' }}
              />
              {selected.thumbnail && (
                <button type="button" className="btn tiny ghost" onClick={() => void removeThumbnail(selected)}>
                  Remove thumbnail
                </button>
              )}
            </figure>
          </div>

          <div className="admin-wide admin-pages">
            <h3>Pages ({selected.pages.length})</h3>
            <ul className="admin-pagelist">
              {selected.pages.map((p, i) => (
                <li key={p.id}>
                  <img src={p.url} alt="" />
                  <span className="admin-trackacts">
                    <button
                      type="button" className="btn tiny ghost" disabled={busy || i === 0}
                      onClick={() => void movePage(selected, p, -1)} aria-label="Move earlier"
                    >
                      ↑
                    </button>
                    <button
                      type="button" className="btn tiny ghost" disabled={busy || i === selected.pages.length - 1}
                      onClick={() => void movePage(selected, p, 1)} aria-label="Move later"
                    >
                      ↓
                    </button>
                    <button type="button" className="btn tiny ghost" onClick={() => void deletePage(p)}>
                      Remove
                    </button>
                  </span>
                </li>
              ))}
              {selected.pages.length === 0 && <li className="muted tiny">No pages yet.</li>}
            </ul>
            <label className="admin-upload">
              <span>{busy ? 'Uploading…' : 'Add pages (pick several at once — they concatenate in the order you pick them)'}</span>
              <input
                type="file" accept="image/*" multiple disabled={busy}
                onChange={(e) => {
                  const files = e.target.files ? Array.from(e.target.files) : []
                  if (files.length) void uploadPages(selected, files)
                  e.target.value = ''
                }}
              />
            </label>
          </div>

          <div className="actionbar admin-acts">
            {confirmDelete === selected.id ? (
              <>
                <span className="admin-bantext">
                  Really delete {selected.title || '(untitled)'} and all {selected.pages.length} of its pages? This cannot be undone.
                </span>
                <button type="button" className="btn danger small" disabled={busy} onClick={() => void deleteChapter(selected.id)}>
                  Yes, delete forever
                </button>
                <button type="button" className="btn ghost small" disabled={busy} onClick={() => setConfirmDelete(null)}>
                  No
                </button>
              </>
            ) : (
              <button type="button" className="btn danger small" disabled={busy} onClick={() => setConfirmDelete(selected.id)}>
                Delete chapter
              </button>
            )}
            {note && <span className="savemark">{note}</span>}
          </div>
          {err && <p className="error admin-wide">{err}</p>}
        </div>
      ) : (
        <p className="muted">Pick a chapter on the left, or start a new one.</p>
      )}
    </div>
  )
}
