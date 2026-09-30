import { levelInfo, useProgression } from '../lib/progression'
import { useT } from '../lib/i18n'

/** 0188: "Level 7" + a bar toward the next one. */
export function LevelBar({ xp, compact = false }: { xp: number | undefined; compact?: boolean }) {
  const t = useT()
  const { levels } = useProgression()
  const info = levelInfo(levels, xp)
  return (
    <div className={`lvlbar${compact ? ' is-compact' : ''}`}>
      <span className="lvlbar-lvl">{t('profile.level', { n: info.level })}</span>
      <span className="lvlbar-track" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(info.pct * 100)}>
        <i style={{ width: `${Math.round(info.pct * 100)}%` }} />
      </span>
      {!compact && (
        <span className="lvlbar-txt">
          {info.span == null ? t('profile.maxLevel') : t('profile.xpProgress', { into: info.into, span: info.span })}
        </span>
      )}
    </div>
  )
}
