import { useEffect, useState } from 'react'
import { useAppSettings, setEffectPcts, setEffectToggles } from '../lib/useAppSettings'
import type { AppSettings } from '../lib/types'

/**
 * Jared: "make it so that in admin panel I have access to these things: how
 * much damage units receive by poison, how much damage units receive by
 * burn... make a checklist [of what triggers burn], make a checklist [of
 * what stun disables]." Then, looking at the checklists once they existed:
 * "I need to check or uncheck these things, it shouldn't be just
 * informative, you know?"
 *
 * Two admin-tunable numbers (same shape as AdminLadder's K-factor and bot
 * fallback seconds: a column on the app_settings singleton, read fresh by
 * the SQL function that matters -- cn_poison_pct()/cn_burn_pct() -- so a
 * change here takes effect on the very next tick/swing/cast, no redeploy),
 * plus two checklists that used to be pure documentation and are now real
 * switches (0157) -- nine more app_settings booleans, one per row, read
 * fresh by cn_burn_applies(kind)/cn_stun_blocks(kind). Every row still
 * shows the fact it always showed (checked = today's actual default), but
 * unchecking one now genuinely changes what the next attack/move/ability/
 * pass does, live, no redeploy:
 *
 *  BURN, unchecked everywhere, never costs the burned unit anything.
 *  Checking "Attacking" or "Using an ability" only makes explicit what
 *  already happened (those two default on). Checking "Moving" or
 *  "Defending" is new behaviour -- 0157 added the cost from scratch, capped
 *  so it can never kill (floored at 1 HP) since cn_move/cn_defend have none
 *  of cn_attack's death/burial/win-check plumbing to hook into. Checking
 *  "Doing nothing (pass)" is also new -- it mirrors poison's own per-turn
 *  tick exactly, including that it CAN kill, and only works in 1v1 (Battle
 *  Royale has no per-turn tick loop of any kind yet to hang it on).
 *
 *  POISON is unaffected by any of this -- still a flat tick at the very
 *  start of the poisoned unit's own turn (advance_turn), before it has
 *  taken any action, no toggle to turn it off.
 *
 *  STUN's four boxes gate an existing refusal (cn_attack/cn_ability/
 *  cn_move/cn_defend, and their royale/bot_step counterparts, already say
 *  'that unit is stunned') -- unchecking one lets a stunned unit do that
 *  one thing anyway. No new mechanic, just whether the door is locked.
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

  // The nine toggles save one at a time, the moment you click -- there is
  // no separate Save for these (unlike the two number fields above), same
  // as AdminLadder's single friend_and_tournament_lp_enabled checkbox.
  // toggleBusy tracks which row (its settings key) is mid-save so only
  // that row's checkbox disables, not the whole table.
  const [toggleBusy, setToggleBusy] = useState<string | null>(null)
  const [toggleErr, setToggleErr] = useState<string | null>(null)

  async function flip(key: EffectToggleKey, next: boolean) {
    setToggleBusy(key); setToggleErr(null)
    try {
      await setEffectToggles({ [key]: next })
    } catch (e) { setToggleErr((e as Error).message) }
    finally { setToggleBusy(null) }
  }

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
        Unchecked, an action costs the burned unit nothing. Checking Moving,
        Defending, or Pass adds a cost that didn't exist before this
        checklist went live -- Moving/Defending are floored at 1 HP (can
        never kill); Pass mirrors poison's tick exactly (can kill) and only
        works in 1v1.
      </p>
      <EffectChecklist
        settings={settings}
        busyKey={toggleBusy}
        onFlip={flip}
        rows={[
          { key: 'burn_on_attack', label: 'Attacking', note: "Either side of the exchange -- the one swinging or the one answering a counter." },
          { key: 'burn_on_ability', label: 'Using an ability', note: 'The caster only. Whatever the ability hits does not also pay this cost.' },
          { key: 'burn_on_move', label: 'Moving', note: 'New mechanic (0157). Floored at 1 HP -- a move alone can never kill.' },
          { key: 'burn_on_defend', label: 'Defending', note: 'New mechanic (0157). Same floor-1 cap as Moving.' },
          { key: 'burn_on_pass', label: 'Doing nothing (pass)', note: "New mechanic (0157), 1v1 only. Mirrors poison's own tick exactly -- this one CAN kill." },
        ]}
      />

      <h3 className="admin-effects-h">What stun actually disables</h3>
      <p className="muted tiny">
        Checked = a stunned unit is refused with "that unit is stunned."
        Unchecking a box lets a stunned unit do that one thing anyway --
        every box defaults checked, matching what 0151 made true for all
        four.
      </p>
      <EffectChecklist
        settings={settings}
        busyKey={toggleBusy}
        onFlip={flip}
        blockedLabel
        rows={[
          { key: 'stun_blocks_attack', label: 'Attacking', note: null },
          { key: 'stun_blocks_ability', label: 'Using an ability', note: null },
          { key: 'stun_blocks_move', label: 'Moving', note: null },
          { key: 'stun_blocks_defend', label: 'Defending', note: null },
        ]}
      />
      {toggleErr && <p className="error tiny">{toggleErr}</p>}
      <p className="muted tiny">
        Clears at the end of the stunned unit's own turn -- it stays in
        effect through the entirety of that unit's own next turn, not just
        the turn it was applied on.
      </p>
    </div>
  )
}

type EffectToggleKey =
  | 'burn_on_attack' | 'burn_on_ability' | 'burn_on_move' | 'burn_on_defend' | 'burn_on_pass'
  | 'stun_blocks_attack' | 'stun_blocks_ability' | 'stun_blocks_move' | 'stun_blocks_defend'

function EffectChecklist({ rows, settings, busyKey, onFlip, blockedLabel }: {
  rows: { key: EffectToggleKey; label: string; note: string | null }[]
  settings: AppSettings
  busyKey: string | null
  onFlip: (key: EffectToggleKey, next: boolean) => void
  /** Burn's checklist reads "does this cost it damage" (Yes/No); stun's
   *  reads "is this blocked" (Blocked/Allowed) -- same shape, opposite
   *  words, so each table says what it means rather than a bare Yes/No
   *  a reader has to remember which way it points. */
  blockedLabel?: boolean
}) {
  return (
    <table className="efftable">
      <tbody>
        {rows.map(({ key, label, note }) => {
          const on = Boolean(settings[key])
          const busy = busyKey === key
          return (
            <tr key={key} className={on ? 'is-on' : 'is-off'}>
              <td className="efftable-icon">
                <input
                  id={`efftoggle-${key}`}
                  type="checkbox"
                  checked={on}
                  disabled={busy}
                  onChange={(e) => onFlip(key, e.target.checked)}
                />
              </td>
              <td className="efftable-label">
                <label htmlFor={`efftoggle-${key}`}>
                  {label}
                  {note && <span className="muted tiny efftable-note">{note}</span>}
                </label>
              </td>
              <td className="efftable-word">
                {busy ? 'Saving…' : blockedLabel ? (on ? 'Blocked' : 'Allowed') : (on ? 'Costs damage' : 'No damage')}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}
