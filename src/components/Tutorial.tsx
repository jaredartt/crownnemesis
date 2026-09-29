import { useRef, useState } from 'react'
import { Board } from './Board'
import { Page } from './Zoom'
import { useT } from '../lib/i18n'
import {
  unitPower, reachText,
  type CardEffect, type Fx, type MatchState, type Unit,
} from '../lib/types'
import { type AnimationSpec } from './AnimationFx'

/**
 * The first-time tutorial. Jared: "a very simple game, no trees anywhere,
 * just both kings, a unit for each side of the board that can attack, and a
 * rigged and scripted kind of combat, so you can explain how things work."
 *
 * This is not a real match -- there is no matchId, no Supabase row, nothing
 * server-side at all. It is the REAL Board component (the exact one every
 * match renders) driven entirely by local state that this file scripts by
 * hand, beat by beat. Board itself cannot tell the difference: it only ever
 * reads `state` and calls back through onMove/onAttack/onAbility, and this
 * file supplies both ends of that contract instead of api.ts and a live
 * database doing it.
 *
 * The two demonstration units are real cards (Eva and Lium), copied here
 * with their real stats and -- for Eva's heal -- her real card_effects row,
 * so the board highlights the same legal tiles and targets it would in a
 * real match. Nothing here reaches the network.
 */

const W = 6
const H = 8

const DEREO_ID = 'tut-dereo'
const EVA_ID = 'tut-eva'
const STELARIS_ID = 'tut-stelaris'
const LIUM_ID = 'tut-lium'

/** Eva's real ON_ABILITY row (card_effects), copied verbatim so Board's own
 *  scripted-ability targeting (THE_TARGET -> aimed at a unit) works exactly
 *  as it does in a real match. See card_effects where card_id = Eva's id. */
const EVA_HEAL_EFFECT: CardEffect = {
  id: '0770ef82-622b-41d1-b702-a37de5a4e971',
  card_id: '5d604105-e958-4a05-82f2-1b8f0e9b3d9a',
  sort: 0,
  trigger: 'ON_ABILITY',
  target_selector: 'THE_TARGET',
  action: 'HEAL',
  value: 20,
  conditions: [],
}

/** Jared: "when it talks about any unit or king on the board, please use
 *  the 'Simple pulse (starter)' animation for it." The exact animations-
 *  table row (slug starter_pulse) copied verbatim, same convention
 *  EVA_HEAL_EFFECT above uses for a card_effects row -- Board has no
 *  opinion on which preset this is, so this is the one place that says. */
const STARTER_PULSE: AnimationSpec = {
  shape: 'pulse_only',
  color: '#2f4bff',
  duration_ms: 500,
  particle_count: 0,
  spread_deg: 360,
  radius_px: 42,
  scale_start: 0.8,
  scale_end: 1.6,
  opacity_start: 0.8,
  opacity_end: 0,
}

type UnitSeed = Pick<
  Unit,
  'id' | 'owner' | 'cardId' | 'slug' | 'name' | 'role' | 'hp' | 'maxHp' | 'mov'
  | 'rmin' | 'rmax' | 'dmin' | 'dmax' | 'pow' | 'accent' | 'art' | 'ability' | 'x' | 'y'
> & Partial<Unit>

/** Fills in every field Unit requires that a demo card doesn't need to vary.
 *  Every flag here is false because all four cards used in this lesson
 *  (Dereo, Stelaris, Eva, Lium) really do have every one of them false --
 *  see the `cards` table -- so this is accurate, not just convenient. */
function unit(seed: UnitSeed): Unit {
  return {
    crmin: seed.rmin,
    crmax: seed.rmax,
    moved: false,
    acted: false,
    burns: false,
    heals: false,
    tramples: false,
    flies: false,
    sneaks: false,
    cures: false,
    parries: false,
    blooms: false,
    parryPct: 5,
    critPct: 5,
    royal: false,
    abilityKind: null,
    effects: {},
    ...seed,
  }
}

function makeDereo(x: number, y: number, hp = 110): Unit {
  return unit({
    id: DEREO_ID, owner: 'host', cardId: 'dereo', slug: 'dereo', name: 'King Dereo',
    role: 'royal', hp, maxHp: 110, mov: 1, rmin: 1, rmax: 1, dmin: 28, dmax: 32, pow: 30,
    accent: '#e8503c', art: 'cards/dereo.webp',
    ability: 'Grants the team minor (15%) resistance to Rogues.',
    royal: true, x, y,
  })
}

function makeStelaris(x: number, y: number): Unit {
  return unit({
    id: STELARIS_ID, owner: 'guest', cardId: 'stelaris', slug: 'stelaris', name: 'King Stelaris',
    role: 'royal', hp: 120, maxHp: 120, mov: 1, rmin: 1, rmax: 1, dmin: 28, dmax: 32, pow: 30,
    accent: '#2f7fd9', art: 'cards/stelaris.webp',
    ability: 'Grants the team minor (15%) resistance to Mages.',
    royal: true, x, y,
  })
}

function makeEva(x: number, y: number, hp = 80): Unit {
  return unit({
    id: EVA_ID, owner: 'host', cardId: 'eva', slug: 'eva', name: 'Eva',
    role: 'rogue', hp, maxHp: 80, mov: 2, rmin: 1, rmax: 2, dmin: 18, dmax: 22, pow: 20,
    accent: '#3f8f4a', art: 'cards/eva.webp',
    ability: 'Heals 20 HP to a target.',
    x, y,
    abilityKind: 'scripted', abilityN: 10, abilityScript: [EVA_HEAL_EFFECT],
    abilityMaxUses: null, abilityCooldownTurns: null, abilityUses: 0, abilityLastUsedTurn: null,
  })
}

function makeLium(x: number, y: number, hp = 70): Unit {
  return unit({
    id: LIUM_ID, owner: 'guest', cardId: 'lium', slug: 'lium', name: 'Lium',
    role: 'knight', hp, maxHp: 70, mov: 1, rmin: 1, rmax: 1, dmin: 28, dmax: 32, pow: 30,
    accent: '#eb5757', art: 'cards/lium.webp',
    ability: "Slightly (5%→10%) increased parry and crit rates. Parries all parries.",
    x, y, parryPct: 10, critPct: 10,
  })
}

/** No obstacles at all -- Jared: "no trees anywhere". */
function baseState(units: Unit[], fx?: Fx): MatchState {
  return {
    v: 1,
    board: { w: W, h: H },
    phase: 'battle',
    ready: { host: true, guest: true },
    obstacles: [],
    turn: 'host',
    turnNumber: 1,
    acts: 0,
    active: null,
    units,
    log: [],
    winner: null,
    fx,
  }
}

/** Board.tsx's own draw()/flipFor('host') turns the host's board-space
 *  TOP half (y < h/2, see rules.ts's ownSide) into the BOTTOM of the
 *  screen -- "you are always at the bottom, looking up", same as every
 *  real match. Dereo/Eva (owner: 'host') sit at y 1-2, Stelaris/Lium
 *  (owner: 'guest') at y 5-6, so the player's own army renders at the
 *  bottom here too, not the top. */
const START = () => baseState([
  makeDereo(3, 1), makeEva(3, 2), makeStelaris(4, 6), makeLium(4, 5),
])

/** After the free movement step: fresh positions, adjacent, so the attack
 *  step is always legal no matter where the player moved Eva to. */
const READY_TO_ATTACK = (eva: Unit) => baseState([
  makeDereo(3, 1), unit({ ...eva, x: 4, y: 4, moved: false, acted: false }),
  makeStelaris(4, 6), makeLium(4, 5),
])

const AFTER_ATTACK = (dmg: number) => (prev: MatchState, seq: number): MatchState => {
  const units = prev.units.map((u) => {
    if (u.id === LIUM_ID) return { ...u, hp: Math.max(0, u.hp - dmg) }
    if (u.id === EVA_ID) return { ...u, acted: true, spent: true }
    return u
  })
  const lium = units.find((u) => u.id === LIUM_ID)!
  const fx: Fx = {
    seq, atk: EVA_ID, tgt: LIUM_ID, dmg, heal: 0,
    killedTgt: lium.hp <= 0, counter: 0, killedAtk: false,
    burnAtk: 0, burnTgt: 0, newBurn: false, cured: false, parry: false, tree: false,
  }
  return { ...prev, units, fx }
}

const RETALIATE = (dmg: number) => (prev: MatchState, seq: number): MatchState => {
  const units = prev.units.map((u) => (
    u.id === EVA_ID ? { ...u, hp: Math.max(0, u.hp - dmg) } : u
  ))
  const fx: Fx = {
    seq, atk: LIUM_ID, tgt: EVA_ID, dmg, heal: 0,
    killedTgt: false, counter: 0, killedAtk: false,
    burnAtk: 0, burnTgt: 0, newBurn: false, cured: false, parry: false, tree: false,
  }
  return { ...prev, units, fx, turn: 'guest' }
}

/** Fresh positions for the ability beat: Dereo down to 90/110 (he "took a
 *  hit earlier") and next to Eva, so the heal always has somewhere legal and
 *  visible to land. */
const READY_TO_HEAL = (eva: Unit) => baseState([
  makeDereo(4, 3, 90), unit({ ...eva, x: 4, y: 4, hp: eva.hp, moved: false, acted: false, spent: false }),
  makeStelaris(4, 6), makeLium(4, 5, 50),
])

const AFTER_HEAL = (heal: number) => (prev: MatchState, seq: number): MatchState => {
  const units = prev.units.map((u) => {
    if (u.id === DEREO_ID) return { ...u, hp: Math.min(u.maxHp, u.hp + heal) }
    if (u.id === EVA_ID) return { ...u, acted: true, spent: true, abilityUses: 1 }
    return u
  })
  const fx: Fx = {
    seq, kind: 'ability', why: 'eva-heal', atk: EVA_ID, tgt: DEREO_ID, dmg: 0, heal,
    killedTgt: false, counter: 0, killedAtk: false,
    burnAtk: 0, burnTgt: 0, newBurn: false, cured: false, parry: false, tree: false,
  }
  return { ...prev, units, fx }
}

type StepId = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9
const LAST_STEP: StepId = 9
/** Which steps wait for a real Board action instead of a "Next" tap. */
const INTERACTIVE: Partial<Record<StepId, true>> = { 3: true, 5: true, 8: true }

/** Which unit(s) each step's narration names -- pulsed with STARTER_PULSE
 *  (see above) the instant that step becomes current, so a player's eye
 *  goes straight to whoever the callout below is talking about. Steps
 *  that only speak in general terms ("a unit's Power stat", "most units
 *  counter-attack") don't name anybody in particular and stay out of
 *  this map. */
const STEP_HIGHLIGHTS: Partial<Record<StepId, readonly string[]>> = {
  1: [DEREO_ID],
  2: [EVA_ID],
  3: [EVA_ID],
  4: [EVA_ID],
  5: [EVA_ID, LIUM_ID],
  6: [LIUM_ID],
  7: [LIUM_ID],
  8: [EVA_ID, DEREO_ID],
  9: [DEREO_ID],
}

export function Tutorial({ onDone }: { onDone: () => void }) {
  const t = useT()
  const [step, setStep] = useState<StepId>(0)
  const [state, setState] = useState<MatchState>(START)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  // A plain ref, not state: this only ever feeds Fx.seq (a value read once,
  // synchronously, before the state update it belongs to), never drives a
  // render on its own. Keeping it out of useState means nextSeq() has no
  // React setState side effect of its own, so it stays safe to call from
  // inside a setState updater -- which AFTER_ATTACK/RETALIATE/AFTER_HEAL's
  // call sites below do not do either, on purpose, for the same reason.
  const seqRef = useRef(0)
  const nextSeq = () => (seqRef.current += 1)

  const advance = () => setStep((s) => (Math.min(LAST_STEP, s + 1) as StepId))

  const eva = state.units.find((u) => u.id === EVA_ID) ?? null

  const goReadyToAttack = () => {
    setSelectedId(null)
    setState(READY_TO_ATTACK(eva!))
    advance()
  }
  const goRetaliate = () => {
    const n = nextSeq()
    setState((prev) => RETALIATE(24)(prev, n))
    advance()
  }
  const goReadyToHeal = () => {
    setSelectedId(null)
    setState(READY_TO_HEAL(eva!))
    advance()
  }
  const finish = () => onDone()

  const handleSelect = (id: string | null) => {
    if (!INTERACTIVE[step]) return
    setSelectedId(id)
  }
  const handleMove = (x: number, y: number) => {
    if (step !== 3 || !selectedId) return
    setState((prev) => ({
      ...prev,
      units: prev.units.map((u) => (u.id === selectedId ? { ...u, x, y, moved: true } : u)),
    }))
    setSelectedId(null)
    advance()
  }
  const handleAttack = (targetId: string) => {
    if (step !== 5 || selectedId !== EVA_ID || targetId !== LIUM_ID) return
    const n = nextSeq()
    setState((prev) => AFTER_ATTACK(20)(prev, n))
    setSelectedId(null)
    advance()
  }
  const handleAbility = (unitId: string, target: string | null) => {
    if (step !== 8 || unitId !== EVA_ID || target !== DEREO_ID) return
    const n = nextSeq()
    setState((prev) => AFTER_HEAL(20)(prev, n))
    setSelectedId(null)
    advance()
  }

  const selected = state.units.find((u) => u.id === selectedId) ?? null
  const locked = !INTERACTIVE[step]

  const copy = STEP_COPY(t)[step]

  return (
    <Page title={t('tutorial.title')} tint="#3f8f4a" onClose={finish} wide>
      <div className="tutorial">
        <div className="arena" style={{ '--cols': W, '--rows': H } as React.CSSProperties}>
          <Board
            state={state}
            mySide="host"
            isMyTurn
            deploying={false}
            selectedId={selectedId}
            onSelect={handleSelect}
            onMove={handleMove}
            onAttack={handleAttack}
            onAbility={handleAbility}
            onDefend={() => {}}
            onDeploy={() => {}}
            onHover={() => {}}
            onPeek={() => {}}
            onLook={() => {}}
            onWatching={() => {}}
            locked={locked}
            pulseIds={STEP_HIGHLIGHTS[step]}
            pulseSeq={step}
            pulseSpec={STARTER_PULSE}
          />
        </div>

        {selected ? (
          <div className="unitbar" style={{ '--accent': selected.accent } as React.CSSProperties}>
            <span className="unitbar-name">{selected.name}</span>
            <span className="unitbar-stats">
              <b>{selected.hp}</b>/{selected.maxHp} {t('stat.hp')}
              <i /><b>{unitPower(selected)}</b> {t(selected.heals ? 'stat.pwr' : 'stat.dmg')}
              <i /><b>{selected.mov}</b> {t('stat.mov')}
              <i /><b>{reachText(selected.rmin, selected.rmax)}</b> {t('stat.rng')}
            </span>
          </div>
        ) : (
          <div className="unitbar is-empty">
            <span className="unitbar-stats">{t('match.pickToRead')}</span>
          </div>
        )}

        <div className="tutorial-callout" role="status">
          <div className="tutorial-dots" aria-hidden="true">
            {Array.from({ length: LAST_STEP + 1 }, (_, i) => (
              <span key={i} className={`tutorial-dot${i === step ? ' is-on' : ''}`} />
            ))}
          </div>
          <p>{copy}</p>
          {!INTERACTIVE[step] && (
            <button
              className="btn primary"
              onClick={() => {
                if (step === 4) goReadyToAttack()
                else if (step === 6) goRetaliate()
                else if (step === 7) goReadyToHeal()
                else if (step === 9) finish()
                else advance()
              }}
            >
              {step === LAST_STEP ? t('tutorial.finish') : t('tutorial.next')}
            </button>
          )}
        </div>
      </div>
    </Page>
  )
}

function STEP_COPY(t: (k: string) => string): Record<StepId, string> {
  return {
    0: t('tutorial.step0'),
    1: t('tutorial.step1'),
    2: t('tutorial.step2'),
    3: t('tutorial.step3'),
    4: t('tutorial.step4'),
    5: t('tutorial.step5'),
    6: t('tutorial.step6'),
    7: t('tutorial.step7'),
    8: t('tutorial.step8'),
    9: t('tutorial.step9'),
  }
}
