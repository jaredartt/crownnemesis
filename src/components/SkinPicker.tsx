import { useState } from 'react'
import { equipSkin } from '../lib/api'
import { levelInfo, ownsSkin, skinLabel, useMyGrants, useProgression } from '../lib/progression'
import type { Profile, SkinKind } from '../lib/types'
import { currentLang, useT } from '../lib/i18n'
import { SkinPreview } from './SkinPreview'

/**
 * 0188: one row of skins of one kind. Owned ones equip on tap (frames and
 * unit looks toggle off again; a name always has SOME colour, so that one
 * only switches). Locked ones are greyed out with the level that earns them.
 * The server re-checks ownership (equip_skin + a guard trigger) -- the grey
 * is a courtesy, not the lock.
 */
export function SkinPicker({ kind, profile, onChanged }: {
  kind: SkinKind
  profile: Profile
  onChanged: (p: Partial<Profile>) => void
}) {
  const t = useT()
  const { skins, levels } = useProgression()
  const grants = useMyGrants(profile.id)
  const [err, setErr] = useState<string | null>(null)
  const level = levelInfo(levels, profile.xp).level
  const equipped = kind === 'unit' ? profile.equipped_unit_skin : kind === 'frame' ? profile.equipped_frame : (profile.name_color ?? 'blue')
  const lang = currentLang()

  const items = skins
    .filter((s) => s.kind === kind)
    .sort((a, b) => (a.unlock_level ?? 9999) - (b.unlock_level ?? 9999) || a.sort - b.sort)

  const patch = (slug: string | null): Partial<Profile> =>
    kind === 'unit' ? { equipped_unit_skin: slug } : kind === 'frame' ? { equipped_frame: slug } : { name_color: slug ?? 'blue' }

  async function pick(slug: string) {
    const next = kind !== 'name_color' && equipped === slug ? null : slug
    setErr(null)
    const prev = equipped ?? null
    onChanged(patch(next))                       // optimistic: it is one tap
    try { await equipSkin(kind, next) }
    catch (e) { setErr((e as Error).message.replace(/^.*?:\s*/, '')); onChanged(patch(prev)) }
  }

  if (items.length === 0) return null
  return (
    <>
      <div className={`pf-skins is-${kind}`}>
        {items.map((s) => {
          const owned = ownsSkin(s, level, grants)
          const on = equipped === s.slug
          const title = owned
            ? `${skinLabel(s, lang)}${s.description ? ` — ${s.description}` : ''}`
            : s.price != null ? `${skinLabel(s, lang)} — ${t('profile.inShop')}`
            : s.unlock_level != null ? `${skinLabel(s, lang)} — ${t('profile.unlocksAt', { n: s.unlock_level })}` : `${skinLabel(s, lang)} — ${t('profile.special')}`
          return (
            <button
              key={s.id} type="button"
              className={`pf-skin${on ? ' is-on' : ''}${owned ? '' : ' is-locked'}`}
              onClick={() => owned && pick(s.slug)}
              aria-pressed={on} aria-disabled={!owned}
              title={title} aria-label={title}
            >
              <SkinPreview skin={s} face={profile.avatar} name={profile.username} />
              <span className="pf-skin-cap">
                {owned ? skinLabel(s, lang) : s.price != null ? `👑 ${s.price}` : s.unlock_level != null ? `🔒 ${t('profile.lvl', { n: s.unlock_level })}` : '🔒'}
              </span>
            </button>
          )
        })}
      </div>
      {err && <p className="error tiny">{err}</p>}
    </>
  )
}
