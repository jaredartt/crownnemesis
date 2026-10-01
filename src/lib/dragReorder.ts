/**
 * Drag-and-drop ordering for every admin list (cards, structures, animations,
 * skins, menu tiles, music, comics).
 *
 * Jared: "Delete the sort property from all things... Let me drag and drop
 * stuff to sort them out instead, I'm sick of always changing a number."
 *
 * Nobody types a sort number any more. Dragging a row writes the new order
 * itself: every row of the dragged row's group gets `sort = its position`
 * (0, 1, 2 ...). The `sort` COLUMN still exists in the database -- it is just
 * where the order is stored, the same way every list on the site already reads
 * it (`.order('sort')`) -- but no form shows it and nothing asks for a value.
 *
 * Usage:
 *   const { view, dragProps } = useDragReorder({
 *     rows, table: 'cards', reload: load, onError: setErr,
 *   })
 *   view.map((r) => <button key={r.id} {...dragProps(r.id)} ... />)
 */
import { useEffect, useRef, useState } from 'react'
import type { DragEvent, HTMLAttributes } from 'react'
import { supabase } from './supabase'

type Sortable = { id: string; sort: number }

/** Writes `sort = index` for every row whose stored number differs. Returns an
 *  error message, or null when everything saved. */
export async function saveOrder(table: string, ordered: Sortable[]): Promise<string | null> {
  const writes = ordered
    .map((r, i) => ({ r, i }))
    .filter(({ r, i }) => r.sort !== i)
    .map(({ r, i }) => supabase.from(table).update({ sort: i }).eq('id', r.id))
  const results = await Promise.all(writes)
  const bad = results.find((x) => x.error)
  return bad?.error ? bad.error.message : null
}

/** The order a brand-new row should take: the end of its list. */
export function nextSort(rows: { sort: number }[]): number {
  return rows.length ? Math.max(...rows.map((r) => r.sort)) + 1 : 0
}

type Edge = 'before' | 'after'

type DragAttrs = HTMLAttributes<HTMLElement> & { draggable: boolean } &
  { [K in `data-${string}`]?: string | undefined }

export function useDragReorder<T extends Sortable>({
  rows, table, reload, onError, group, horizontal,
}: {
  rows: T[]
  table: string
  /** called after the new order is saved, to re-read the list */
  reload?: () => unknown
  onError?: (message: string) => void
  /** rows only reorder among rows that share this value (e.g. skin kind) */
  group?: (row: T) => string
  /** the list runs left-to-right (a grid of thumbnails), not top-to-bottom */
  horizontal?: boolean
}) {
  const [dragId, setDragId] = useState<string | null>(null)
  const [over, setOver] = useState<{ id: string; edge: Edge } | null>(null)
  // The order we just dropped, shown until the reload lands so the row does
  // not jump back for a moment.
  const [local, setLocal] = useState<string[] | null>(null)
  const alive = useRef(true)
  useEffect(() => () => { alive.current = false }, [])

  const view = local
    ? [...rows].sort((a, b) => local.indexOf(a.id) - local.indexOf(b.id))
    : rows

  const groupOf = (id: string) => {
    const r = rows.find((x) => x.id === id)
    return r && group ? group(r) : ''
  }

  async function drop(targetId: string, edge: Edge) {
    const from = dragId
    setDragId(null); setOver(null)
    if (!from || from === targetId) return
    if (groupOf(from) !== groupOf(targetId)) return
    const without = view.filter((r) => r.id !== from)
    const moved = view.find((r) => r.id === from)
    const at = without.findIndex((r) => r.id === targetId)
    if (!moved || at < 0) return
    const next = [...without]
    next.splice(edge === 'before' ? at : at + 1, 0, moved)
    setLocal(next.map((r) => r.id))
    const members = next.filter((r) => (group ? group(r) === groupOf(from) : true))
    const err = await saveOrder(table, members)
    if (err) onError?.(err)
    await reload?.()
    if (alive.current) setLocal(null)
  }

  /** The drop-target half: put this on the row. Also carries the
   *  dragging / drop-line markers the stylesheet draws. */
  function rowProps(id: string): DragAttrs {
    const here = over && over.id === id ? over.edge : null
    return {
      onDragOver: (e: DragEvent<HTMLElement>) => {
        if (!dragId || dragId === id || groupOf(dragId) !== groupOf(id)) return
        e.preventDefault()
        e.dataTransfer.dropEffect = 'move'
        const b = e.currentTarget.getBoundingClientRect()
        const edge: Edge = horizontal
          ? (e.clientX < b.left + b.width / 2 ? 'before' : 'after')
          : (e.clientY < b.top + b.height / 2 ? 'before' : 'after')
        if (!over || over.id !== id || over.edge !== edge) setOver({ id, edge })
      },
      onDrop: (e: DragEvent<HTMLElement>) => {
        e.preventDefault()
        void drop(id, over && over.id === id ? over.edge : 'before')
      },
      draggable: false,
      'data-reorder-row': '',
      'data-drag': dragId === id ? 'dragging' : undefined,
      'data-drop': here ?? undefined,
    }
  }

  /** The grab half: put this on whatever should start the drag. On a row that
   *  has inputs or sliders inside it, put it on a small handle instead of the
   *  row, so dragging a slider never drags the row. */
  function handleProps(id: string): DragAttrs {
    return {
      draggable: true,
      onDragStart: (e: DragEvent<HTMLElement>) => {
        setDragId(id)
        e.dataTransfer.effectAllowed = 'move'
        e.dataTransfer.setData('text/plain', id)
        const row = e.currentTarget.closest('[data-reorder-row]')
        if (row) e.dataTransfer.setDragImage(row, 12, 12)
      },
      onDragEnd: () => { setDragId(null); setOver(null) },
    }
  }

  /** Whole row is the handle (rows with nothing to type into). */
  function dragProps(id: string): DragAttrs {
    return { ...rowProps(id), ...handleProps(id) }
  }

  return { view, dragProps, rowProps, handleProps, dragging: dragId !== null }
}
