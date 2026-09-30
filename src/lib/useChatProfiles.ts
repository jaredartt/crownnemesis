import { useEffect, useState } from 'react'
import { getMatchIntroProfiles } from './api'

/**
 * Profile pictures for the people in a chat.
 *
 * Jared: "in chat, people should not only show the color of their name that
 * they chose, but also their profile pic next to their username." A chat row
 * only carries the sender's id, name and colour (copied onto the row when it
 * was written), and the avatar is deliberately NOT frozen onto it -- so a
 * new picture shows on old messages too. This looks the ids up once and keeps
 * the answers for the life of the page, so a long chat is one small query per
 * new voice rather than one per message.
 */
const cache = new Map<string, string | null>()

export function useChatAvatars(userIds: string[]): Record<string, string | null> {
  const [, bump] = useState(0)
  const key = [...new Set(userIds)].sort().join(',')

  useEffect(() => {
    const missing = key ? key.split(',').filter((id) => !cache.has(id)) : []
    if (missing.length === 0) return
    let alive = true
    getMatchIntroProfiles(missing).then((found) => {
      for (const id of missing) cache.set(id, found[id]?.avatar ?? null)
      if (alive) bump((n) => n + 1)
    })
    return () => { alive = false }
  }, [key])

  const out: Record<string, string | null> = {}
  if (key) for (const id of key.split(',')) out[id] = cache.get(id) ?? null
  return out
}
