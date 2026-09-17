import { useState } from 'react'
import { AdminCards } from './AdminCards'
import { AdminStructures } from './AdminStructures'
import { AdminMusic } from './AdminMusic'
import { AdminMenu } from './AdminMenu'
import { AdminUsers } from './AdminUsers'

const TABS = [
  ['cards', 'Cards'],
  // Since 0057: a brand-new content type, its own tab -- see
  // AdminStructures.tsx's own header and 0057_structures.sql for why it
  // is not folded into the Cards tab.
  ['structures', 'Structures'],
  ['music', 'Music'],
  ['menu', 'Menu'],
  ['users', 'Users'],
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
      <div className="admintabs" role="tablist">
        {TABS.map(([id, label]) => (
          <button
            key={id} type="button" role="tab" aria-selected={tab === id}
            className={tab === id ? 'is-on' : ''}
            onClick={() => setTab(id)}
          >
            {label}
          </button>
        ))}
      </div>
      <div className="admintab-body">
        {tab === 'cards' && <AdminCards />}
        {tab === 'structures' && <AdminStructures />}
        {tab === 'music' && <AdminMusic />}
        {tab === 'menu' && <AdminMenu />}
        {tab === 'users' && <AdminUsers />}
      </div>
    </div>
  )
}
