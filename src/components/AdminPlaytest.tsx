import { useState } from 'react'
import { ptNew } from '../lib/api'
import { PLAYTEST_IDS } from './PlaytestMatch'

/**
 * Admin Mode -> Playtest. One button: it opens your sandbox room on a fresh
 * board with a new random set of trees. See PlaytestMatch.tsx for what the
 * room is, and 0213_playtest.sql for what the server does differently in it.
 */
export function AdminPlaytest({ onEnter }: { onEnter: (matchId: string) => void }) {
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function open() {
    setBusy(true)
    setErr(null)
    try {
      const m = await ptNew()
      PLAYTEST_IDS.add(m.id)
      onEnter(m.id)
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <section className="admin-playtest">
      <h2>Playtest</h2>
      <p>
        A sandbox where you play both teams. Drop any card or structure onto the board at any
        moment, hand any unit to the other team, and pass turns whenever you like. It runs the
        same rules as a 1v1 match, because it is one, so it always matches the real game. Nobody
        wins, there is no clock, and nobody else can join or watch.
      </p>
      <button className="btn primary" disabled={busy} onClick={open}>
        {busy ? 'Opening…' : 'Open playtest'}
      </button>
      {err && <p className="toast-inline">{err}</p>}
    </section>
  )
}
