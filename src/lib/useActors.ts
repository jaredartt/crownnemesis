import { useEffect, useState } from 'react'
import { supabase } from './supabase'

/**
 * How somebody looks to everyone else: the icon they picked, the colour of
 * their name, and their frame. Notifications only carry an id and a username
 * (that is all the server stamps into them), so the bell asks for the rest here.
 *
 * One request per batch of ids it has not seen, cached for the session -- a
 * list of notifications naming the same three people costs three rows, once.
 */
export interface Actor { avatar: string | null; name_color: string | null; frame: string | null }

const cache = new Map<string, Actor>()
const listeners = new Set<() => void>()

async function load(ids: string[]) {
  const { data } = await supabase
    .from('profiles').select('id, avatar, name_color, equipped_frame').in('id', ids)
  for (const r of (data ?? []) as { id: string; avatar: string | null; name_color: string | null; equipped_frame: string | null }[]) {
    cache.set(r.id, { avatar: r.avatar, name_color: r.name_color, frame: r.equipped_frame })
  }
  // Remember the ones that came back empty too, so they are not asked for again.
  for (const id of ids) if (!cache.has(id)) cache.set(id, { avatar: null, name_color: null, frame: null })
  listeners.forEach((l) => l())
}

export function useActors(ids: (string | undefined)[]): Map<string, Actor> {
  const [, bump] = useState(0)
  const wanted = [...new Set(ids.filter((x): x is string => Boolean(x)))].filter((id) => !cache.has(id))
  const key = wanted.join(',')
  useEffect(() => {
    const l = () => bump((n) => n + 1)
    listeners.add(l)
    return () => { listeners.delete(l) }
  }, [])
  useEffect(() => {
    if (!key) return
    void load(key.split(','))
  }, [key])
  return cache
}
