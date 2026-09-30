import { useEffect, useState } from 'react'
import { getMyTournamentEntry, type MyTournamentEntry } from './api'

/**
 * 0192: "am I signed up for a tournament?" -- shared by the top bar, the
 * Ranked confirmation and the tab-closing goodbye. One poller for everybody
 * who asks (ref-counted), refreshed at once whenever the tournament screen
 * joins/leaves (api.ts fires 'cn:tournament'), on focus, and every 12s.
 */
let entry: MyTournamentEntry | null = null
let loaded = false
let userId: string | null = null
let timer: ReturnType<typeof setInterval> | null = null
const listeners = new Set<() => void>()

async function refresh() {
  if (!userId) return
  const id = userId
  const next = await getMyTournamentEntry(id).catch(() => entry)
  if (id !== userId) return
  const same = JSON.stringify(next) === JSON.stringify(entry)
  entry = next; loaded = true
  if (!same) listeners.forEach((l) => l())
}
const onEvent = () => { void refresh() }
const onVisible = () => { if (document.visibilityState === 'visible') void refresh() }

function start(id: string) {
  if (userId !== id) { userId = id; entry = null; loaded = false }
  void refresh()
  if (!timer) {
    timer = setInterval(() => { void refresh() }, 12_000)
    window.addEventListener('cn:tournament', onEvent)
    document.addEventListener('visibilitychange', onVisible)
  }
}
function stop() {
  if (listeners.size > 0) return
  if (timer) clearInterval(timer)
  timer = null
  window.removeEventListener('cn:tournament', onEvent)
  document.removeEventListener('visibilitychange', onVisible)
}

export function useMyTournament(id: string | undefined): { entry: MyTournamentEntry | null; loaded: boolean } {
  const [, bump] = useState(0)
  useEffect(() => {
    if (!id) return
    const l = () => bump((n) => n + 1)
    listeners.add(l)
    start(id)
    return () => { listeners.delete(l); stop() }
  }, [id])
  return { entry: id && userId === id ? entry : null, loaded }
}
