import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { setCardValueParams, useAppSettings } from '../lib/useAppSettings'
import { cardValue, statusTone, valueStatus } from '../lib/cardValue'
import type { Card } from '../lib/types'

/**
 * Admin Mode -> Card value. The price list behind the "value" number shown beside a
 * card in the Cards tab, and the band that number should land in:
 *
 *   value = HP x per-HP + Attack x per-attack + Range x per-range + Move x per-move + class bonus
 *
 * A design aid only: nothing in a match reads it, and changing it changes no card. Under
 * the min the card's number shows red, over the max red, within the warning margin of
 * either edge yellow, otherwise green. Below the form is every active card priced with
 * the numbers on screen (before you save), so a change to the list shows its effect on
 * the whole roster at once.
 */
type Key =
  | 'vp_per_hp' | 'vp_per_attack' | 'vp_per_range' | 'vp_per_move'
  | 'vp_class_royal' | 'vp_class_rogue' | 'vp_class_knight' | 'vp_class_mage' | 'vp_class_flying'
  | 'vp_min' | 'vp_max' | 'vp_warn'

const FIELDS: { key: Key; label: string; note?: string; def: number; int?: boolean }[] = [
  { key: 'vp_per_hp', label: '1 HP is worth', def: 1, note: 'VP' },
  { key: 'vp_per_attack', label: '1 Attack is worth', def: 10, note: 'VP' },
  { key: 'vp_per_range', label: '1 Range is worth', def: 30, note: 'VP' },
  { key: 'vp_per_move', label: '1 Move is worth', def: 20, note: 'VP' },
  { key: 'vp_class_royal', label: 'Class: Royal adds', def: 0, note: 'VP (flat)' },
  { key: 'vp_class_rogue', label: 'Class: Rogue adds', def: 0, note: 'VP (flat)' },
  { key: 'vp_class_knight', label: 'Class: Knight adds', def: 0, note: 'VP (flat)' },
  { key: 'vp_class_mage', label: 'Class: Mage adds', def: 0, note: 'VP (flat)' },
  { key: 'vp_class_flying', label: 'Class: Flying adds', def: 0, note: 'VP (flat)' },
  { key: 'vp_min', label: 'Minimum value for a card', def: 250, int: true },
  { key: 'vp_max', label: 'Maximum value for a card', def: 500, int: true },
  { key: 'vp_warn', label: 'Warning margin (yellow within this of min or max)', def: 25, int: true },
]

type S = ReturnType<typeof useAppSettings>
const fromSettings = (s: S): Record<Key, string> =>
  Object.fromEntries(FIELDS.map((f) => [f.key, String(s[f.key] ?? f.def)])) as Record<Key, string>

export function AdminCardValue() {
  const settings = useAppSettings()
  const [draft, setDraft] = useState<Record<Key, string>>(() => fromSettings(settings))
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [cards, setCards] = useState<Pick<Card, 'id' | 'name' | 'role' | 'hp' | 'mov' | 'range' | 'power' | 'dmin' | 'dmax'>[]>([])

  useEffect(() => { if (!dirty) setDraft(fromSettings(settings)) }, [settings, dirty])
  useEffect(() => {
    void (async () => {
      const { data } = await supabase.from('cards')
        .select('id, name, role, hp, mov, range, power, dmin, dmax').eq('is_active', true).order('sort')
      setCards((data ?? []) as typeof cards)
    })()
  }, [])

  const parsed = Object.fromEntries(FIELDS.map((f) => {
    const n = Number(draft[f.key])
    return [f.key, draft[f.key].trim() !== '' && Number.isFinite(n) ? (f.int ? Math.round(n) : Math.round(n * 100) / 100) : NaN]
  })) as Record<Key, number>
  const bad = FIELDS.filter((f) => Number.isNaN(parsed[f.key]))
  const badBand = !bad.length && parsed.vp_min > parsed.vp_max

  const live = { ...settings, ...parsed }
  const priced = cards
    .map((c) => ({ c, v: cardValue(c as Card, live) }))
    .sort((a, b) => a.v - b.v)

  async function save() {
    setBusy(true); setErr(null); setSaved(false)
    try { await setCardValueParams(parsed); setDirty(false); setSaved(true) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="admin-rules">
      <h2>Card value</h2>
      <p className="muted tiny">
        How the value next to a card in the Cards tab is worked out, and the band it should stay in.
        Value = HP, Attack, Range and Move each times its price, plus the class bonus. A design aid:
        nothing in a match uses it. Changes are live the moment you save.
      </p>
      <form onSubmit={(e) => { e.preventDefault(); if (!bad.length && !badBand) void save() }}>
        <div className="valuepage-grid">
          {FIELDS.map((f) => (
            <label key={f.key}>
              <span>{f.label}{f.note ? ` (${f.note})` : ''}</span>
              <input
                type="number" step={f.int ? 1 : 0.01} value={draft[f.key]}
                onChange={(e) => { setDirty(true); setSaved(false); setDraft((d) => ({ ...d, [f.key]: e.target.value })) }}
              />
              <span className="muted tiny">default {f.def}</span>
            </label>
          ))}
        </div>
        <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
          <button className="btn primary" disabled={busy || !dirty || bad.length > 0 || badBand}>
            {busy ? 'Saving…' : 'Save'}
          </button>
          <button
            type="button" className="btn ghost" disabled={busy}
            onClick={() => { setDirty(true); setSaved(false); setDraft(Object.fromEntries(FIELDS.map((f) => [f.key, String(f.def)])) as Record<Key, string>) }}
          >
            Back to defaults
          </button>
          {saved && <span className="muted tiny">Saved. Live now.</span>}
        </div>
        {bad.length > 0 && <p className="error tiny">Not a number: {bad.map((f) => f.label).join(', ')}.</p>}
        {badBand && <p className="error tiny">The minimum is above the maximum.</p>}
        {err && <p className="error tiny">{err}</p>}
      </form>

      <h3 style={{ marginTop: 24 }}>The roster at these prices</h3>
      <table className="valuepage-list">
        <tbody>
          {priced.map(({ c, v }) => {
            const tone = statusTone(valueStatus(v, live))
            return (
              <tr key={c.id}>
                <td>{c.name}</td>
                <td className="muted tiny">{c.role}</td>
                <td className={`is-${tone}`}>{v}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
