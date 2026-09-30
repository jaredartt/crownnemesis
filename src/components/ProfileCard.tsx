import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { setAvatar, setCountry, setDescription, setUsername } from '../lib/api'
import { containsSlur, wordCount, DESCRIPTION_MAX_WORDS } from '../lib/profanity'
import type { Card, Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { Avatar } from './Avatar'
import { Achievements } from './Achievements'
import { Modal } from './Modal'
import { CountryPicker } from './CountryPicker'
import { LevelBar } from './LevelBar'
import { SkinPicker } from './SkinPicker'

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
  const [desc, setDesc] = useState(profile.description ?? '')
  const [descBusy, setDescBusy] = useState(false)
  const [descSaved, setDescSaved] = useState(false)
  const [descErr, setDescErr] = useState<string | null>(null)

  // Jared: "if it contains a bad word in one of these fields, some red words
  // next to it saying the [username/description] can't contain slurs, and it
  // won't let you save until there's no slurs." Checked as you type, with the
  // same algorithm the server runs (lib/profanity.ts <-> cn_slur_check).
  const nameSlur = containsSlur(name)
  const descSlur = containsSlur(desc)
  const words = wordCount(desc)
  const descTooLong = words > DESCRIPTION_MAX_WORDS
  const descDirty = desc.trim() !== (profile.description ?? '').trim()

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

  async function rename() {
    const v = name.trim()
    if (v === profile.username || containsSlur(v)) return
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

  async function pickCountry(code: string | null) {
    const prev = profile.country ?? null
    setErr(null)
    onChanged({ country: code })                           // optimistic: it is one tap
    try { await setCountry(code) }
    catch (e) { setErr((e as Error).message); onChanged({ country: prev }) }
  }

  async function saveDescription() {
    if (descSlur || descTooLong) return
    setDescBusy(true); setDescErr(null); setDescSaved(false)
    try {
      const got = await setDescription(desc)
      onChanged({ description: got })
      setDesc(got ?? '')
      setDescSaved(true)
    } catch (e) {
      setDescErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setDescBusy(false)
    }
  }

  return (
    <Modal title={t('profile.title')} onClose={onClose}>
      <div className="pf">
        <div className="pf-you">
          <Avatar slug={profile.avatar} name={profile.username} size={72} className="is-big" frame={profile.equipped_frame} />
          <div className="pf-name">
            <div className="pf-labelrow">
              <label htmlFor="pf-username">{t('profile.name')}</label>
              {nameSlur && <span className="pf-slur" role="alert">{t('profile.slurUsername')}</span>}
            </div>
            <div className="pf-rename">
              <input
                id="pf-username" value={name} maxLength={20} autoComplete="off"
                onChange={(e) => { setName(e.target.value); setSaved(false) }}
                onKeyDown={(e) => { if (e.key === 'Enter') rename() }}
              />
              <button
                className="btn small primary"
                disabled={busy || nameSlur || !name.trim() || name.trim() === profile.username}
                onClick={rename}
              >
                {busy ? t('common.saving') : saved ? t('common.saved') : t('profile.save')}
              </button>
            </div>
            <p className="muted tiny">{t('profile.nameRules')}</p>

            {/* Jared: "add a profile description inside the profile button,
                right below the name... max 100 words." */}
            <div className="pf-labelrow">
              <label htmlFor="pf-desc">{t('profile.description')}</label>
              {descSlur && <span className="pf-slur" role="alert">{t('profile.slurDescription')}</span>}
            </div>
            <textarea
              id="pf-desc" className="pf-desc" rows={3} value={desc} maxLength={900}
              placeholder={t('profile.descriptionPlaceholder')}
              onChange={(e) => { setDesc(e.target.value); setDescSaved(false); setDescErr(null) }}
            />
            <div className="pf-descfoot">
              <span className={`tiny ${descTooLong ? 'pf-slur' : 'muted'}`}>
                {t('profile.words', { n: words, max: DESCRIPTION_MAX_WORDS })}
              </span>
              <button
                className="btn small primary"
                disabled={descBusy || descSlur || descTooLong || !descDirty}
                onClick={saveDescription}
              >
                {descBusy ? t('common.saving') : descSaved && !descDirty ? t('common.saved') : t('profile.save')}
              </button>
            </div>
            {descErr && <p className="error tiny">{descErr}</p>}
          </div>
        </div>

        <LevelBar xp={profile.xp} />

        {/* Shows to everyone: the Ladder's flag column and your card. */}
        <h3 className="pf-title">{t('profile.country')}</h3>
        <CountryPicker value={profile.country ?? null} allowNone onChange={pickCountry} />

        {/* Jared: "The profile name color chooser should be above the
            profile icons." Was face-grid then color row; just the two
            sections swapped, nothing about either one changed. */}
        <h3 className="pf-title">{t('profile.pickColor')}</h3>
        <SkinPicker kind="name_color" profile={profile} onChanged={onChanged} />
        <h3 className="pf-title">{t('profile.pickFrame')}</h3>
        <SkinPicker kind="frame" profile={profile} onChanged={onChanged} />
        <h3 className="pf-title">{t('profile.pickUnitSkin')}</h3>
        <SkinPicker kind="unit" profile={profile} onChanged={onChanged} />
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

        {err && <p className="error">{err}</p>}

        <Achievements profile={profile} onChanged={onChanged} />
      </div>
    </Modal>
  )
}
