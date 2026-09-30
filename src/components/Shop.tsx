import { useEffect, useMemo, useState } from 'react'
import { buySkin, equipSkin, getMyBalance } from '../lib/api'
import { currentLang, useT } from '../lib/i18n'
import { levelInfo, ownsSkin, skinLabel, useMyGrants, useProgression } from '../lib/progression'
import type { Profile, Skin, SkinKind } from '../lib/types'
import { IconCrown } from './Icons'
import { SkinPreview } from './SkinPreview'

/**
 * 0191: the Shop. Gradient frames, glowing/shimmering unit looks and coloured
 * name effects are bought here with Crowns -- the in-game money earned by
 * levelling up and winning ranked matches (amounts live in Admin -> Levels).
 * The plain skins stay on the level track and never appear here.
 *
 * The server is the lock: `buy_skin` checks price, ownership and balance in one
 * transaction. The disabled buttons below are courtesy, not protection.
 */
const KINDS: SkinKind[] = ['name_color', 'unit', 'frame']

export function Shop({ profile, onProfile }: {
  profile: Profile
  onProfile: (patch: Partial<Profile>) => void
}) {
  const t = useT()
  const lang = currentLang()
  const { skins, levels, rules } = useProgression()
  const [grantKey, setGrantKey] = useState(0)
  const grants = useMyGrants(profile.id, grantKey)
  const [filter, setFilter] = useState<'all' | SkinKind>('all')
  const [confirm, setConfirm] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [justBought, setJustBought] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const crowns = profile.crowns ?? 0
  const level = levelInfo(levels, profile.xp).level

  // The balance may have moved since the profile was loaded (a match paid out).
  useEffect(() => {
    let alive = true
    void getMyBalance(profile.id).then((b) => { if (alive && b) onProfile({ crowns: b.crowns, xp: b.xp }) })
    return () => { alive = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profile.id])

  const forSale = useMemo(
    () => skins.filter((s) => s.price != null && s.is_active)
      .sort((a, b) => (a.price ?? 0) - (b.price ?? 0) || a.sort - b.sort),
    [skins],
  )
  const kindLabel: Record<SkinKind, string> = {
    name_color: t('shop.nameColors'), unit: t('shop.unitLooks'), frame: t('shop.frames'),
  }
  const shownKinds = filter === 'all' ? KINDS : [filter]

  const rankedWin = rules.find((r) => r.mode === 'ranked' && r.result === 'win')?.crowns ?? 0
  const nextLevelPay = levels.find((l) => l.level === level + 1)?.crowns ?? 0

  const isEquipped = (s: Skin) =>
    s.kind === 'unit' ? profile.equipped_unit_skin === s.slug
    : s.kind === 'frame' ? profile.equipped_frame === s.slug
    : profile.name_color === s.slug

  async function buy(s: Skin) {
    setBusy(s.slug); setErr(null)
    try {
      const bal = await buySkin(s.slug)
      onProfile({ crowns: bal })
      setGrantKey((k) => k + 1)
      setConfirm(null)
      setJustBought(s.slug)
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(null)
    }
  }

  async function equip(s: Skin) {
    setBusy(s.slug); setErr(null)
    try {
      await equipSkin(s.kind, s.slug)
      onProfile(s.kind === 'unit' ? { equipped_unit_skin: s.slug } : s.kind === 'frame' ? { equipped_frame: s.slug } : { name_color: s.slug })
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="shop">
      <div className="shop-wallet">
        <span className="shop-wallet-ico"><IconCrown /></span>
        <div className="shop-wallet-txt">
          <span className="shop-wallet-label">{t('shop.balance')}</span>
          <b className="shop-wallet-amt">{crowns.toLocaleString()}</b>
        </div>
        <div className="shop-earn">
          <p>{t('shop.earn')}</p>
          <p className="shop-earn-pay">
            {rankedWin > 0 && <span>{t('shop.earnRanked', { n: rankedWin })}</span>}
            {nextLevelPay > 0 && <span>{t('shop.earnLevel', { n: nextLevelPay })}</span>}
          </p>
        </div>
      </div>

      <div className="seg shop-filter" role="radiogroup" aria-label={t('shop.title')}>
        {(['all', ...KINDS] as const).map((k) => (
          <button key={k} type="button" role="radio" aria-checked={filter === k}
                  className={filter === k ? 'is-on' : ''} onClick={() => setFilter(k)}>
            {k === 'all' ? t('shop.all') : kindLabel[k]}
          </button>
        ))}
      </div>

      {err && <p className="error tiny">{err}</p>}
      {forSale.length === 0 && <p className="muted">{t('shop.empty')}</p>}

      {shownKinds.map((k) => {
        const items = forSale.filter((s) => s.kind === k)
        if (items.length === 0) return null
        return (
          <section key={k} className="shop-group">
            <h4 className="shop-grouphead">{kindLabel[k]} <span>{items.length}</span></h4>
            <div className="shop-grid">
              {items.map((s) => {
                const owned = ownsSkin(s, level, grants)
                const price = s.price ?? 0
                const short = Math.max(0, price - crowns)
                const asking = confirm === s.slug
                const fresh = justBought === s.slug
                return (
                  <div key={s.id} className={`shop-item${owned ? ' is-owned' : ''}`} data-kind={s.kind}>
                    <div className="shop-item-art">
                      <SkinPreview skin={s} face={profile.avatar} name={profile.username} />
                    </div>
                    <div className="shop-item-name" title={s.description ?? undefined}>{skinLabel(s, lang)}</div>

                    {owned ? (
                      <div className="shop-item-foot">
                        {isEquipped(s)
                          ? <span className="shop-tag is-on">{t('shop.equipped')}</span>
                          : (
                            <button type="button" className="btn tiny ghost" disabled={busy === s.slug} onClick={() => void equip(s)}>
                              {fresh ? t('shop.equipNow') : t('shop.equip')}
                            </button>
                          )}
                      </div>
                    ) : asking ? (
                      <div className="shop-item-foot shop-confirm">
                        <span className="shop-confirm-q">{t('shop.buyFor', { name: skinLabel(s, lang), n: price })}</span>
                        <span className="shop-confirm-btns">
                          <button type="button" className="btn tiny primary" disabled={busy === s.slug} onClick={() => void buy(s)}>{t('shop.confirm')}</button>
                          <button type="button" className="btn tiny ghost" onClick={() => setConfirm(null)}>{t('shop.cancel')}</button>
                        </span>
                      </div>
                    ) : (
                      <div className="shop-item-foot">
                        <button
                          type="button" className="shop-buy" disabled={short > 0 || busy != null}
                          onClick={() => { setErr(null); setConfirm(s.slug) }}
                        >
                          <IconCrown /> <b>{price.toLocaleString()}</b>
                          <span className="shop-buy-act">{short > 0 ? t('shop.need', { n: short.toLocaleString() }) : t('shop.buy')}</span>
                        </button>
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          </section>
        )
      })}
    </div>
  )
}
