import { useEffect, useMemo, useRef } from 'react'
import type { LogEntry } from '../lib/types'
import { useT } from '../lib/i18n'
import { LOG_ICONS } from '../lib/logIcons'
import { logKind, parseTurnLine, splitNames } from '../lib/logEvents'

interface NamedUnit { name: string; owner: string | number }

/* Jared: every unit named in the log is bold and in its class colour; every
   line has an icon (Tabler); each new turn opens with a black divider; and
   unit names are bold -- blue for your units, red for the opponent's. */
export function BattleLog({ log, open, units, mineOwner }: {
  log: LogEntry[]
  open: boolean
  /** Units on the board now. Remembered for the life of the log, so a unit that
   *  has fallen is still bold and coloured in the lines about it. */
  units?: NamedUnit[]
  /** Which `owner` is "you" (your side, or your seat in Royale). A spectator
   *  gets the host as blue. */
  mineOwner?: string | number
}) {
  const t = useT()
  const endRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [log.length])

  const seen = useRef(new Map<string, string>())
  const roles = useMemo(() => {
    for (const u of units ?? []) if (u.name) seen.current.set(u.name, u.owner === mineOwner ? 'mine' : 'foe')
    return new Map(seen.current)
  }, [units, mineOwner])

  return (
    <aside className={`side side-right${open ? ' is-open' : ''}`}>
      <h2 className="side-title">{t('log.title')}</h2>
      <div className="side-body">
        {log.map((e) => {
          const turn = parseTurnLine(e.text)
          if (turn) {
            return (
              <div key={e.n} className="logturn">
                <span className="logturn-txt">{e.text}</span>
              </div>
            )
          }
          const kind = logKind(e.text)
          return (
            <div key={e.n} className="logline">
              <svg
                className="log-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"
                                dangerouslySetInnerHTML={{ __html: LOG_ICONS[kind.icon] }}
              />
              <span>
                {splitNames(e.text, roles).map((p, i) =>
                  p.role === undefined
                    ? <span key={i}>{p.text}</span>
                    : <b key={i} className={`logname is-${p.role}`}>{p.text}</b>)}
              </span>
            </div>
          )
        })}
        <div ref={endRef} />
      </div>
    </aside>
  )
}
