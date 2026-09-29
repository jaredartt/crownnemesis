import { useState } from 'react'
import { AdminCards } from './AdminCards'
import { AdminStructures } from './AdminStructures'
import { AdminMusic } from './AdminMusic'
import { AdminComics } from './AdminComics'
import { AdminMenu } from './AdminMenu'
import { AdminUsers } from './AdminUsers'
import { AdminLadder } from './AdminLadder'
import { AdminEffects } from './AdminEffects'
import { AdminAnimations } from './AdminAnimations'
import { AdminStats } from './AdminStats'
import {
  IconBolt, IconBook, IconCards, IconChart, IconLadder, IconMenuLines, IconMusic, IconPerson,
  IconSparkle, IconStructure,
} from './Icons'

/** Jared: "put a relevant simple icon at the left side of each of these
 *  things, with a color assigned to the icons? And if you click it, the
 *  border of the button will have the color of that icon." One colour per
 *  tab, reusing a tile's own tint from Lobby.tsx wherever this tab is
 *  plainly the same subject there (Comics, Ladder) so the two screens agree
 *  on what that colour means; a fresh one everywhere else this row covers
 *  ground the front menu doesn't. */
const TABS = [
  ['cards', 'Cards', IconCards, '#d92d20'],
  // Since 0057: a brand-new content type, its own tab -- see
  // AdminStructures.tsx's own header and 0057_structures.sql for why it
  // is not folded into the Cards tab.
  ['structures', 'Structures', IconStructure, '#a0522d'],
  ['music', 'Music', IconMusic, '#7c3aed'],
  ['comics', 'Comics', IconBook, '#0f8b8d'],
  ['menu', 'Menu', IconMenuLines, '#e8701a'],
  ['users', 'Users', IconPerson, '#d9a41b'],
  // Item 7: a temporary, admin-toggleable ruleset flag -- its own small
  // tab rather than folded into Users or Menu, since it is neither a
  // per-user nor a per-tile setting. See AdminLadder.tsx.
  ['ladder', 'Ladder', IconLadder, '#2f4bff'],
  // Jared: "make it so that in admin panel I have access to [poison/burn
  // damage, and what burn/stun actually trigger on]." See AdminEffects.tsx.
  ['effects', 'Effects', IconBolt, '#16a34a'],
  // 0158: Jared -- "Create a new tab inside the admin panel where I can
  // define, create, modify and delete animations." A colour of its own,
  // distinct from every tint above (including Music's own #7c3aed --
  // that's a tab tint, this is a different UI element entirely, so the
  // two are never seen side by side). See AdminAnimations.tsx.
  ['animations', 'Animations', IconSparkle, '#e0458a'],
  // Jared: "I think it would be cool to know all the data that is
  // happening in the game... so that I can improve the game and adjust
  // accordingly." See AdminStats.tsx -- last connection + match counts per
  // player, day/week/month volume, and the feedback/bug inbox the Settings
  // button now feeds. A colour of its own, distinct from every tint above.
  ['stats', 'Activity', IconChart, '#0a8043'],
] as const
type Tab = (typeof TABS)[number][0]

/**
 * The whole of Admin Mode, one tab at a time.
 *
 * Access is decided before this ever mounts -- Lobby.tsx renders it only
 * behind `canAdmin`, which is `profile.is_admin` AND the signed-in email
 * being jaredartt@gmail.com (see App.tsx) -- so nothing in here re-checks who
 * is allowed to be looking at it. That is deliberate: the real lock is the
 * server's, cn_is_super_admin() in 0039_super_admin.sql, which every write
 * this panel can make is checked against regardless of what this component
 * does or does not render.
 */
export function AdminPanel() {
  const [tab, setTab] = useState<Tab>('cards')
  return (
    <div className="adminpanel">
      <div className="admintabs admintabs-main" role="tablist">
        {TABS.map(([id, label, Icon, tint]) => (
          <button
            key={id} type="button" role="tab" aria-selected={tab === id}
            className={tab === id ? 'is-on' : ''}
            style={{ '--tab-tint': tint } as React.CSSProperties}
            onClick={() => setTab(id)}
          >
            <Icon className="admintab-icon" />
            {label}
          </button>
        ))}
      </div>
      <div className="admintab-body">
        {tab === 'cards' && <AdminCards />}
        {tab === 'structures' && <AdminStructures />}
        {tab === 'music' && <AdminMusic />}
        {tab === 'comics' && <AdminComics />}
        {tab === 'menu' && <AdminMenu />}
        {tab === 'users' && <AdminUsers />}
        {tab === 'ladder' && <AdminLadder />}
        {tab === 'effects' && <AdminEffects />}
        {tab === 'animations' && <AdminAnimations />}
        {tab === 'stats' && <AdminStats />}
      </div>
    </div>
  )
}
