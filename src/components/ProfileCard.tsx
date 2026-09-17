import { useEffect, useState, type CSSProperties } from 'react'
import { supabase } from '../lib/supabase'
import { setAvatar, setNameColor, setUsername } from '../lib/api'
import { NAME_COLORS } from '../lib/nameColors'
import type { Card, Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { Avatar } from './Avatar'
import { Achievements } from './Achievements'
import { Modal } from './Modal'

/**
 * Who you are: a face out of the roster and a name.
 *
 * The icon saves the moment you pick one -- it is one tap and there is nothing
 * to get wrong. The name does not: a name is typed, and typing wants a moment
 * to change your mind before anyone else sees it.
 */
export function ProfileCard({
  profile, onClose, onChanged,
}: {
  profile: Profile
  onClose: () => void
  onChanged: (p: Partial<Profile>) => void
}) {
  const t = useT()
  const [roster, setRoster] = useState<Card[]>([])
  const [name, setName] = useState(profile.username)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    supabase.from('cards').select('*').eq('is_active', true).order('sort')
      .then(({ data }) => data && setRoster(data as Card[]))
  }, [])

  async function pick(slug: string) {
    const next = profile.avatar === slug ? null : slug     // tap it again to clear
    setErr(null)
    onChanged({ avatar: next })                            // optimistic: it is one tap
    try { await setAvatar(next) }
    catch (e) { setErr((e as Error).message); onChanged({ avatar: profile.avatar }) }
  }

  async function pickColor(color: string) {
    if (color === profile.name_color) return
    setErr(null)
    const prev = profile.name_color
    onChanged({ name_color: color })                       // optimistic: it is one tap
    try { await setNameColor(color) }
    catch (e) { setErr((e as Error).message); onChanged({ name_color: prev }) }
  }

  async function rename() {
    const v = name.trim()
    if (v === profile.username) return
    setBusy(true); setErr(null); setSaved(false)
    try {
      const got = await setUsername(v)
      onChanged({ username: got })
      setSaved(true)
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title={t('profile.title')} onClose={onClose}>
      <div className="pf">
        <div className="pf-you">
          <Avatar slug={profile.avatar} name={profile.username} size={72} className="is-big" />
          <div className="pf-name">
            <label htmlFor="pf-username">{t('profile.name')}</label>
            <div className="pf-rename">
              <input
                id="pf-username" value={name} maxLength={20} autoComplete="off"
                onChange={(e) => { setName(e.target.value); setSaved(false) }}
                onKeyDown={(e) => { if (e.key === 'Enter') rename() }}
              />
              <button
                className="btn small primary"
                disabled={busy || !name.trim() || name.trim() === profile.username}
                onClick={rename}
              >
                {busy ? t('common.saving') : saved ? t('common.saved') : t('profile.save')}
              </button>
            </div>
            <p className="muted tiny">{t('profile.nameRules')}</p>
          </div>
        </div>

        <h3 className="pf-title">{t('profile.pickFace')}</h3>
        <div className="pf-grid">
          {roster.map((c) => (
            <button
              key={c.id}
              className={`pf-pick${profile.avatar === c.slug ? ' is-on' : ''}`}
              onClick={() => pick(c.slug)}
              title={c.name}
              aria-pressed={profile.avatar === c.slug}
              aria-label={c.name}
            >
              {/* No caption. The faces ARE the labels -- you are picking the
                  one you recognise, not reading a list -- and the names cost
                  a row of 10px text under every tile for nothing. The name
                  still reaches a screen reader and a tooltip through the
                  button's title and aria-label. */}
              <Avatar slug={c.slug} name={c.name} size={80} />
            </button>
          ))}
        </div>
        <h3 className="pf-title">{t('profile.pickColor')}</h3>
        <div className="pf-colors">
          {NAME_COLORS.map((c) => (
            <button
              key={c}
              className={`pf-color${(profile.name_color ?? 'blue') === c ? ' is-on' : ''}`}
              style={{ '--pf-c': `var(--nc-${c})` } as CSSProperties}
              onClick={() => pickColor(c)}
              title={c}
              aria-pressed={(profile.name_color ?? 'blue') === c}
              aria-label={c}
            />
          ))}
        </div>

        {err && <p className="error">{err}</p>}

        <Achievements profile={profile} onChanged={onChanged} />
      </div>
    </Modal>
  )
}
