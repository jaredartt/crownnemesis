import { useEffect, useState } from 'react'
import { useAppSettings, setEffectPcts } from '../lib/useAppSettings'
import { IconCheck, IconClose } from './Icons'

/**
 * Jared: "make it so that in admin panel I have access to these things: how
 * much damage units receive by poison, how much damage units receive by
 * burn... make a checklist [of what triggers burn], make a checklist [of
 * what stun disables]."
 *
 * Two admin-tunable numbers (same shape as AdminLadder's K-factor and bot
 * fallback seconds: a column on the app_settings singleton, read fresh by
 * the SQL function that matters -- cn_poison_pct()/cn_burn_pct() -- so a
 * change here takes effect on the very next tick/swing/cast, no redeploy),
 * plus two read-only checklists that are not a setting at all -- they are
 * what the rules ALREADY do, traced through cn_attack, cn_ability, cn_move,
 * cn_defend and advance_turn this session so this screen states it as fact
 * rather than as a guess:
 *
 *  BURN only ever costs the burned unit something when THAT unit takes an
 *  action -- attacking (whichever side of the exchange it lands on: the
 *  one swinging or the one answering) or casting an ability (itself only;
 *  whatever the ability hits does not also pay burn's cost). Moving and
 *  defending never touch it, and neither does simply ending a turn without
 *  acting -- a burned unit that only moves, only defends, or only passes
 *  takes no burn damage that turn at all.
 *
 *  POISON is the opposite shape entirely: a flat tick at the very start of
 *  the poisoned unit's own turn (advance_turn), before it has taken any
 *  action -- attack, ability, move, defend, or doing nothing all cost
 *  exactly the same: whatever the poison tick already charged that turn.
 *
 *  STUN (0151, same session) now blocks all four outright: a stunned unit
 *  cannot attack, cannot use its ability, cannot move, and cannot defend,
 *  clearing only when its own owner ends its turn.
 */
export function AdminEffects() {
  const settings = useAppSettings()

  const [poison, setPoison] = useState(String(settings.poison_pct))
  const [burn, setBurn] = useState(String(settings.burn_pct))
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (dirty) return
    setPoison(String(settings.poison_pct))
    setBurn(String(settings.burn_pct))
  }, [settings.poison_pct, settings.burn_pct, dirty])

  async function save() {
    const p = Math.max(1, Math.min(100, Math.round(Number(poison)) || settings.poison_pct))
    const b = Math.max(1, Math.min(100, Math.round(Number(burn)) || settings.burn_pct))
    setBusy(true); setErr(null)
    try {
      await setEffectPcts({ poison_pct: p, burn_pct: b })
      setDirty(false)
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  // A live worked example, same idea as AdminLadder's Elo preview: a
  // 100-max-HP unit, so the percentage IS the number, whatever is
  // currently in the (unsaved) draft fields.
  const previewPoison = Math.max(1, Math.round(Number(poison)) || settings.poison_pct)
  const previewBurn = Math.max(1, Math.round(Number(burn)) || settings.burn_pct)

  return (
    <div className="admin-effects">
      <form
        className="admin-grid admin-nums"
        onSubmit={(e) => { e.preventDefault(); void save() }}
      >
        <label><span>Poison damage (% of max HP)</span>
          <input
            type="number" min={1} max={100} value={poison}
            onChange={(e) => { setDirty(true); setPoison(e.target.value) }}
          />
        </label>
        <label><span>Burn damage (% of max HP)</span>
          <input
            type="number" min={1} max={100} value={burn}
            onChange={(e) => { setDirty(true); setBurn(e.target.value) }}
          />
        </label>
        <button className="btn small" disabled={busy || !dirty}>
          {busy ? 'Saving…' : 'Save'}
        </button>
      </form>
      <p className="muted tiny">
        A percentage of the AFFLICTED unit's own max HP, rounded, at least
        1 either way (an aura that resists status effects can still cut the
        final number further). On a unit with 100 max HP that's{' '}
        {previewPoison} from poison and {previewBurn} from burn, at these
        settings. Read fresh the moment either damage type would apply, so
        this takes effect immediately -- no redeploy.
      </p>
      {err && <p className="error tiny">{err}</p>}

      <hr className="matchend-divider" />

      <h3 className="admin-effects-h">When burn actually hurts</h3>
      <p className="muted tiny">
        Only as the cost of the BURNED unit itself taking an action --
        never as a per-turn tick the way poison is.
      </p>
      <EffectChecklist
        rows={[
          ['Attacking', true, "Either side of the exchange -- the one swinging or the one answering a counter."],
          ['Using an ability', true, 'The caster only. Whatever the ability hits does not also pay this cost.'],
          ['Moving', false, null],
          ['Defending', false, null],
          ['Doing nothing (pass)', false, 'No action, no cost -- burn never ticks on its own.'],
        ]}
      />

      <h3 className="admin-effects-h">What stun actually disables</h3>
      <p className="muted tiny">
        Everything. Fixed this session (0151) -- it used to only block
        attacking and using an ability.
      </p>
      <EffectChecklist
        rows={[
          ['Attacking', true, null],
          ['Using an ability', true, null],
          ['Moving', true, null],
          ['Defending', true, null],
        ]}
        blockedLabel
      />
      <p className="muted tiny">
        Clears at the end of the stunned unit's own turn -- it stays in
        effect through the entirety of that unit's own next turn, not just
        the turn it was applied on.
      </p>
    </div>
  )
}

function EffectChecklist({ rows, blockedLabel }: {
  rows: [label: string, on: boolean, note: string | null][]
  /** Burn's checklist reads "does this cost it damage" (Yes/No); stun's
   *  reads "is this blocked" (Blocked/Allowed) -- same shape, opposite
   *  words, so each table says what it means rather than a bare Yes/No
   *  a reader has to remember which way it points. */
  blockedLabel?: boolean
}) {
  return (
    <table className="efftable">
      <tbody>
        {rows.map(([label, on, note]) => (
          <tr key={label} className={on ? 'is-on' : 'is-off'}>
            <td className="efftable-icon" aria-hidden="true">
              {on ? <IconCheck className="efftable-yes" /> : <IconClose className="efftable-no" />}
            </td>
            <td className="efftable-label">
              {label}
              {note && <span className="muted tiny efftable-note">{note}</span>}
            </td>
            <td className="efftable-word">
              {blockedLabel ? (on ? 'Blocked' : 'Allowed') : (on ? 'Costs damage' : 'No damage')}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
