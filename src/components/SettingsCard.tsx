import { supabase } from '../lib/supabase'
import { setSettings, useSettings, type Lang, type Theme, type CineMode } from '../lib/settings'
import { loadLang, useT } from '../lib/i18n'
import { playHit } from '../lib/sfx'
import { IconGear, IconLang, IconMotion, IconMusic, IconSignOut, IconSound, IconTheme, IconCine } from './Icons'
import { Modal } from './Modal'

/** A row: an icon, a label, and the one control that changes it. */
function Row({
  icon, label, note, children,
}: {
  icon: React.ReactNode
  label: string
  note?: string
  children: React.ReactNode
}) {
  return (
    <div className="set-row">
      <span className="set-icon">{icon}</span>
      <span className="set-label">
        {label}
        {note && <em>{note}</em>}
      </span>
      <span className="set-control">{children}</span>
    </div>
  )
}

export function SettingsCard({ onClose, canAdmin, onOpenAdmin }: {
  onClose: () => void
  /** Since 0039. Both halves of the lock -- is_admin AND the signed-in
   *  email -- decided once in App.tsx and threaded down through Lobby.tsx,
   *  so this row is drawn for one account in the world. */
  canAdmin: boolean
  onOpenAdmin: () => void
}) {
  const s = useSettings()
  const t = useT()

  return (
    <Modal title={t('settings.title')} onClose={onClose}>
      <div className="settings">
        <Row icon={<IconSound />} label={t('settings.sfx')} note={`${Math.round(s.sfx * 100)}%`}>
          <input
            type="range" min={0} max={100} value={Math.round(s.sfx * 100)}
            aria-label={t('settings.sfxVolume')}
            onChange={(e) => setSettings({ sfx: Number(e.target.value) / 100 })}
            // A volume slider you cannot hear is a guess, so every notch
            // plays -- and it plays a blow rather than a button, because the
            // loudest thing this number controls is the fighting. Previewing
            // with the quietest sound in the set is how you set it too high.
            onMouseUp={() => playHit(0.6)}
            onKeyUp={() => playHit(0.6)}
          />
        </Row>

        <Row icon={<IconMusic />} label={t('settings.music')} note={t('settings.musicNote')}>
          <input
            type="range" min={0} max={100} value={Math.round(s.music * 100)}
            aria-label={t('settings.musicVolume')}
            onChange={(e) => setSettings({ music: Number(e.target.value) / 100 })}
          />
        </Row>

        {/* Three states and not a switch. "Follow the system" is a real
            answer and the one most people want, and a two-position toggle
            cannot hold it -- it would have to be a switch plus a second
            control to say whether the switch counts. */}
        <Row icon={<IconTheme />} label={t('settings.theme')} note={t('settings.themeNote')}>
          <div className="seg" role="radiogroup" aria-label={t('settings.theme')}>
            {/* The key is written out rather than built from the value.
                Building it produced `settings.themeSystem` for a value of
                'system' while the dictionary says `themeAuto` -- the button
                rendered its own key on screen, and no amount of checking the
                dictionaries against each other could see it, because a
                constructed key is invisible to a search. */}
            {([['system', 'settings.themeAuto'],
               ['light', 'settings.themeLight'],
               ['dark', 'settings.themeDark']] as [Theme, string][]).map(([v, key]) => (
              <button
                key={v}
                role="radio"
                aria-checked={s.theme === v}
                className={s.theme === v ? 'is-on' : ''}
                onClick={() => setSettings({ theme: v })}
              >
                {t(key)}
              </button>
            ))}
          </div>
        </Row>

        {/* Three positions, and the middle one is the interesting one: 'off'
            is not "no feedback", it is "no takeover" -- the board's own lunges
            and damage numbers stay whichever way this points. */}
        <Row icon={<IconCine />} label={t('settings.cine')} note={t('settings.cineNote')}>
          <div className="seg" role="radiogroup" aria-label={t('settings.cine')}>
            {/* Written out, not built. See the theme above for the bug that
                taught this file to do it that way. */}
            {([['full', 'settings.cineFull'],
               ['quick', 'settings.cineQuick'],
               ['off', 'settings.cineOff']] as [CineMode, string][]).map(([v, key]) => (
              <button
                key={v}
                role="radio"
                aria-checked={s.cine === v}
                className={s.cine === v ? 'is-on' : ''}
                onClick={() => setSettings({ cine: v })}
              >
                {t(key)}
              </button>
            ))}
          </div>
        </Row>

        {/* The languages name themselves. A Spanish reader looking for Spanish
            is looking for the word "Español", not for whatever the interface
            they cannot read calls it -- so these two are the one pair of words
            in the app that do NOT get translated. */}
        <Row icon={<IconLang />} label={t('settings.language')} note={t('settings.languageNote')}>
          <div className="seg" role="radiogroup" aria-label={t('settings.language')}>
            {([['en', 'English'], ['es', 'Español']] as [Lang, string][]).map(([v, label]) => (
              <button
                key={v}
                role="radio"
                aria-checked={s.lang === v}
                className={s.lang === v ? 'is-on' : ''}
                onClick={() => { void loadLang(v); setSettings({ lang: v }) }}
              >
                {label}
              </button>
            ))}
          </div>
        </Row>

        <Row
          icon={<IconMotion />}
          label={t('settings.reduceMotion')}
          note={t('settings.reduceMotionNote')}
        >
          <button
            className={`toggle${s.reduceMotion ? ' is-on' : ''}`}
            role="switch" aria-checked={s.reduceMotion}
            aria-label={t('settings.reduceMotion')}
            onClick={() => setSettings({ reduceMotion: !s.reduceMotion })}
          >
            <i />
          </button>
        </Row>

        <div className="set-sep" />

        <button className="set-row is-action" onClick={() => supabase.auth.signOut()}>
          <span className="set-icon"><IconSignOut /></span>
          <span className="set-label">{t('common.signOut')}</span>
        </button>

        {/* IN ENGLISH ONLY, ON PURPOSE, same as the tabs behind it -- see
            AdminCards.tsx's own comment. Drawn last and behind its own
            separator so it reads as a door out of the ordinary settings
            rather than one more of them. */}
        {canAdmin && (
          <>
            <div className="set-sep" />
            <button className="set-row is-action is-admin" onClick={onOpenAdmin}>
              <span className="set-icon"><IconGear /></span>
              <span className="set-label">
                Admin Mode
                <em>Cards, sounds, the menu, and everyone's account</em>
              </span>
            </button>
          </>
        )}
      </div>
    </Modal>
  )
}
