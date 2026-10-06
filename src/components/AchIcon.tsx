import { Ti } from './Ti'

/** An achievement's picture: a Tabler icon in the colour of the emoji it
 *  replaced. The definitions (lib/achievements.ts) still carry the emoji as the
 *  key, so nothing there changed. */
const ACH: Record<number, { name: string; color: string; filled?: boolean }> = {
  0x1F916: { name: 'robot', color: '#7d8da1' },                 // bot wins
  0x1F3C6: { name: 'trophy', color: '#f2b01e', filled: true },  // ranked wins
  0x26A1:  { name: 'bolt', color: '#f5c518', filled: true },    // critical hits
  0x1F6E1: { name: 'shield', color: '#8d96a3', filled: true },  // parries
  0x2694:  { name: 'swords', color: '#8d96a3' },                // knight
  0x1F5E1: { name: 'sword', color: '#8d96a3' },                 // rogue
  0x1F52E: { name: 'crystal-ball', color: '#8e5cf0' },          // mage
  0x1FAB6: { name: 'feather', color: '#5aa9d6', filled: true }, // flying
}

export function AchIcon({ icon }: { icon: string }) {
  const a = ACH[icon.codePointAt(0) ?? 0]
  if (!a) return <>{icon}</>
  return <Ti name={a.name} filled={a.filled} size="1em" style={{ color: a.color, verticalAlign: '-0.125em' }} />
}
