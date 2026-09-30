import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { setAvatar, setCountry, setDescription, setUsername } from '../lib/api'
import { containsSlur, wordCount, DESCRIPTION_MAX_WORDS } from '../lib/profanity'
import type { Card, Profile } from '../lib/types'
import { currentLang, useT } from '../lib/i18n'
import { nameColorStyle } from '../lib/nameColors'
import { Avatar } from './Avatar'
import { AchievementPicker, AchievementSlots, useUnlockedAchievements } from './Achievements'
import { Modal } from './Modal'
import { CountryPicker } from './CountryPicker'
import { LevelBar } from './LevelBar'
import { SkinPicker } from './SkinPicker'
import { UnitSkinPreview } from './SkinPreview'
import { IconFrame, IconPalette, IconPencil } from './Icons'
import { getSkin, skinLabel, useProgression } from '../lib/progression'

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
  // Which screen of the profile is showing. The main screen is one centred
  // stack; the pickers replace it (with a Back) rather than stacking modals.
  const [view, setView] = useState<'main' | 'icons' | 'frame' | 'color' | 'unit' | 'ach0' | 'ach1' | 'ach2'>('main')
  const unlocked = useUnlockedAchievements(profile.id)
  useProgression()
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

  const unitSkin = getSkin('unit', profile.equipped_unit_skin)
  const nameDirty = name.trim() !== profile.username
  const titles: Record<string, string> = {
    icons: t('profile.pickFace'), frame: t('profile.pickFrame'), color: t('profile.pickColor'),
    unit: t('profile.pickUnitSkin'), ach0: t('profile.achievementSlots'), ach1: t('profile.achievementSlots'), ach2: t('profile.achievementSlots'),
  }

  if (view !== 'main') {
    return (
      <Modal title={t('profile.title')} onClose={onClose}>
        <div className="pf pf2">
          <div className="pf2-subhead">
            <button type="button" className="btn small ghost" onClick={() => setView('main')}>‹ {t('profile.back')}</button>
            <h3 className="pf-title">{titles[view]}</h3>
          </div>
          {view === 'icons' && (
            <div className="pf-grid">
              {roster.map((c) => (
                <button
                  key={c.id} className={`pf-pick${profile.avatar === c.slug ? ' is-on' : ''}`}
                  onClick={() => { void pick(c.slug); setView('main') }}
                  title={c.name} aria-pressed={profile.avatar === c.slug} aria-label={c.name}
                >
                  <Avatar slug={c.slug} name={c.name} size={80} />
                </button>
              ))}
            </div>
          )}
          {view === 'frame' && <SkinPicker kind="frame" profile={profile} onChanged={onChanged} />}
          {view === 'color' && <SkinPicker kind="name_color" profile={profile} onChanged={onChanged} />}
          {view === 'unit' && <SkinPicker kind="unit" profile={profile} onChanged={onChanged} />}
          {(view === 'ach0' || view === 'ach1' || view === 'ach2') && (
            <AchievementPicker
              profile={profile} slot={Number(view.slice(3))} unlocked={unlocked}
              onChanged={onChanged} onDone={() => setView('main')}
            />
          )}
          {err && <p className="error">{err}</p>}
        </div>
      </Modal>
    )
  }

  return (
    <Modal title={t('profile.title')} onClose={onClose}>
      <div className="pf pf2">
        {/* The icon: big, centred. Tap it for every icon (the pencil says so);
            the ring button at its left changes its border. */}
        <div className="pf2-hero">
          <button type="button" className="pf2-side" onClick={() => setView('frame')}
                  title={t('profile.editFrame')} aria-label={t('profile.editFrame')}>
            <IconFrame />
          </button>
          <button type="button" className="pf2-avatar" onClick={() => setView('icons')}
                  title={t('profile.editIcon')} aria-label={t('profile.editIcon')}>
            <Avatar slug={profile.avatar} name={profile.username} size={128} className="is-big" frame={profile.equipped_frame} />
            <span className="pf2-pencil" aria-hidden="true"><IconPencil /></span>
          </button>
        </div>

        <LevelBar xp={profile.xp} />

        <div className="pf2-namewrap">
          <div className="pf2-namerow">
            <button type="button" className="pf2-side is-small" onClick={() => setView('color')}
                    title={t('profile.editColor')} aria-label={t('profile.editColor')}>
              <IconPalette />
            </button>
            <input
              id="pf-username" className="pf2-name" value={name} maxLength={20} autoComplete="off"
              aria-label={t('profile.name')} style={nameColorStyle(profile.name_color)}
              onChange={(e) => { setName(e.target.value); setSaved(false) }}
              onKeyDown={(e) => { if (e.key === 'Enter') rename() }}
            />
            <button
              className="btn small primary pf2-namesave"
              disabled={busy || nameSlur || !nameDirty}
              onClick={rename}
              style={nameDirty || saved ? undefined : { visibility: 'hidden' }}
            >
              {busy ? t('common.saving') : saved && !nameDirty ? t('common.saved') : t('profile.save')}
            </button>
          </div>
          {nameSlur && <span className="pf-slur" role="alert">{t('profile.slurUsername')}</span>}
        </div>

        {/* Shows to everyone: the Ladder's flag column and your card. */}
        <div className="pf2-block">
          <h3 className="pf-title">{t('profile.country')}</h3>
          <div className="pf2-flag"><CountryPicker value={profile.country ?? null} allowNone onChange={pickCountry} /></div>
        </div>

        <div className="pf2-block">
          <div className="pf-labelrow">
            <label className="pf-title" htmlFor="pf-desc">{t('profile.description')}</label>
            {descSlur && <span className="pf-slur" role="alert">{t('profile.slurDescription')}</span>}
          </div>
          <textarea
            id="pf-desc" className="pf-desc pf2-desc" rows={3} value={desc} maxLength={900}
            placeholder={t('profile.descriptionPlaceholder')}
            onChange={(e) => { setDesc(e.target.value); setDescSaved(false); setDescErr(null) }}
          />
          <div className="pf-descfoot pf2-descfoot">
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

        <div className="pf2-block">
          <h3 className="pf-title">{t('profile.unitLook')}</h3>
          <button type="button" className="pf2-slot" onClick={() => setView('unit')} title={t('profile.tapToChange')}>
            {unitSkin
              ? <><UnitSkinPreview skin={unitSkin} size={52} /><span>{skinLabel(unitSkin, currentLang())}</span></>
              : <><span className="pf2-slot-empty" aria-hidden="true">+</span><span className="muted">{t('profile.tapToChange')}</span></>}
          </button>
        </div>

        <div className="pf2-block">
          <h3 className="pf-title">{t('profile.achievementSlots')}</h3>
          <AchievementSlots profile={profile} onOpen={(i) => setView(`ach${i}` as 'ach0' | 'ach1' | 'ach2')} />
        </div>

        {err && <p className="error">{err}</p>}
      </div>
    </Modal>
  )
}
