import { useEffect, useState } from 'react'
import { setGameRules, useAppSettings } from '../lib/useAppSettings'

/**
 * Admin Mode -> Rules (0215). The numbers that shape a match, editable without a
 * redeploy. Every one is a column on the app_settings row, read fresh by the
 * server function that enforces it (cn_action_seconds(), cn_deploy_seconds(),
 * cn_acts_cap(), cn_turn_cap(), cn_stalemate_rounds(), cn_gen_trees()), and
 * mirrored in the client by applyRuleSettings() (types.ts) for the clock and the
 * goes pips. The columns have check constraints, so a silly number is refused by
 * the database, not stored.
 *
 * What a change touches: the turn clock and the number of goes apply from the
 * next turn that starts; the turn limit and stalemate rule apply the next time a
 * turn passes (so they can end a running match); trees are laid out when a match
 * is created, so only new matches (and "New board" in the Playtest) use them.
 */
type Key = 'turn_seconds' | 'deploy_seconds' | 'opening_acts' | 'acts_per_turn' | 'turn_cap' | 'stalemate_rounds' | 'trees_per_half' | 'royale_units'
const FIELDS: { key: Key; label: string; min: number; max: number; def: number; note: string }[] = [
  { key: 'turn_seconds', label: 'Turn clock (seconds)', min: 10, max: 180, def: 30,
    note: 'One clock per turn, all goes inside it. Applies from the next turn that starts.' },
  { key: 'deploy_seconds', label: 'Deployment clock (seconds)', min: 20, max: 600, def: 90,
    note: 'How long each player has to place their units before the battle starts.' },
  { key: 'opening_acts', label: 'Goes on the opening turn', min: 1, max: 5, def: 1,
    note: 'The first turn of a match. 1 keeps the first mover from getting a free double move.' },
  { key: 'acts_per_turn', label: 'Goes every other turn', min: 1, max: 5, def: 2,
    note: 'Units that can act per turn after the opening one (1v1; Battle Royale keeps its own single go).' },
  { key: 'turn_cap', label: 'Turn limit', min: 6, max: 200, def: 40,
    note: 'Past this turn number the match ends as a draw. Playtest rooms ignore it.' },
  { key: 'stalemate_rounds', label: 'Stalemate (rounds with no damage)', min: 0, max: 30, def: 5,
    note: 'This many full rounds without a single point of damage ends the match as a draw. 0 turns the rule off (the turn limit still applies).' },
  { key: 'royale_units', label: 'Battle Royale units per player', min: 2, max: 6, def: 4,
    note: 'How many of a kingdom\'s cards go into a Battle Royale: the royal figure always, plus the first cards in kingdom order. Applies to matches that start after you save.' },
  { key: 'trees_per_half', label: 'Trees per half of the board', min: 0, max: 4, def: 4,
    note: 'Laid out when a match is created. The board only has room for 4 per half.' },
]

export function AdminRules() {
  const settings = useAppSettings()
  const [draft, setDraft] = useState<Record<Key, string>>(() => fromSettings(settings))
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  useEffect(() => { if (!dirty) setDraft(fromSettings(settings)) }, [settings, dirty])

  const parsed = Object.fromEntries(FIELDS.map((f) => {
    const n = Math.round(Number(draft[f.key]))
    return [f.key, Number.isFinite(n) ? n : NaN]
  })) as Record<Key, number>
  const bad = FIELDS.filter((f) => !(parsed[f.key] >= f.min && parsed[f.key] <= f.max))

  async function save() {
    setBusy(true); setErr(null); setSaved(false)
    try {
      await setGameRules(parsed)
      setDirty(false); setSaved(true)
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="admin-rules">
      <h2>Game rules</h2>
      <p className="muted tiny">
        The numbers behind every match. Changes are live for everybody the moment you save; no redeploy.
      </p>
      <form onSubmit={(e) => { e.preventDefault(); if (!bad.length) void save() }}>
        <div className="rules-list">
          {FIELDS.map((f) => (
            <label key={f.key} className={`rules-row${bad.includes(f) ? ' is-bad' : ''}`}>
              <span className="rules-name">{f.label}</span>
              <input
                type="number" min={f.min} max={f.max} value={draft[f.key]}
                onChange={(e) => { setDirty(true); setSaved(false); setDraft((d) => ({ ...d, [f.key]: e.target.value })) }}
              />
              <span className="rules-range">{f.min}–{f.max} · default {f.def}</span>
              <span className="rules-note muted tiny">{f.note}</span>
            </label>
          ))}
        </div>
        <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
          <button className="btn primary" disabled={busy || !dirty || bad.length > 0}>
            {busy ? 'Saving…' : 'Save rules'}
          </button>
          <button
            type="button" className="btn ghost" disabled={busy}
            onClick={() => { setDirty(true); setSaved(false); setDraft(Object.fromEntries(FIELDS.map((f) => [f.key, String(f.def)])) as Record<Key, string>) }}
          >
            Back to defaults
          </button>
          {saved && <span className="muted tiny">Saved. Live now.</span>}
        </div>
        {bad.length > 0 && <p className="error tiny">Out of range: {bad.map((f) => f.label).join(', ')}.</p>}
        {err && <p className="error tiny">{err}</p>}
      </form>
    </div>
  )
}

function fromSettings(s: ReturnType<typeof useAppSettings>): Record<Key, string> {
  return Object.fromEntries(FIELDS.map((f) => [f.key, String(s[f.key] ?? f.def)])) as Record<Key, string>
}
