/**
 * The update log shown in Settings -> "Update log".
 *
 * One entry per thing a player could notice, written for players (not the
 * commit message it came from). `at` is when it shipped (UTC), taken from the
 * git history for everything before this file existed. `icon` is a Tabler icon
 * name (lib/tablerIcons.ts) and `color` a hex that says what kind of change it
 * is -- see the legend below.
 *
 * TO ADD AN ENTRY: append one line at the END of ENTRIES with the current time.
 * Order in the file does not matter; the screen sorts newest first.
 *
 * Colours: red = fighting / combat, purple = abilities & effects, green =
 * board & units, blue = menus / interface / sound, pink = card looks & art,
 * gold = ranked, tournaments & rewards, orange = social & modes, teal =
 * bots, tools & behind the scenes.
 */
export type ChangeEntry = {
  at: string
  title: string
  body: string
  icon: string
  color: string
}

const RED = '#e5484d', PURPLE = '#8e4ec6', GREEN = '#2e9e5b', BLUE = '#2f6fe4',
  PINK = '#e5589b', GOLD = '#d99a1c', ORANGE = '#f0803c', TEAL = '#12a594'

const e = (at: string, icon: string, color: string, title: string, body: string): ChangeEntry =>
  ({ at: `2026-${at.slice(0, 5)}T${at.slice(6)}:00Z`, title, body, icon, color })

// Format: e('MM-DD HH:MM', icon, colour, title, body)
export const ENTRIES: ChangeEntry[] = [
  e('09-03 19:25', 'swords', RED, 'The first battle', 'Crown Nemesis begins: online rooms and a placeholder board to fight on.'),
  e('09-04 10:40', 'sword', RED, 'Counterattacks', 'Hits get answered, attacks animate, and a Smash-style action menu appears.'),
  e('09-04 12:00', 'ladder', GOLD, 'Ladder and rematches', 'A hidden rating, a visible ladder, results that outlive the room, and rematch invites.'),
  e('09-05 07:44', 'star', PINK, 'The mark', 'The logo, favicon and app icons arrive.'),
  e('09-05 12:57', 'tree', GREEN, 'Units, terrain and deployment', 'Real units, trees on the board, decks, and a blind deployment phase.'),
  e('09-05 20:39', 'robot', TEAL, 'Bots and the queue', 'A bot to practise against, and a ranked queue to climb.'),
  e('09-06 12:46', 'cards', PURPLE, 'Eight characters', 'Each with something only it can do.'),
  e('09-06 13:58', 'cards', PINK, 'The card, as printed', 'Cards drawn the way they would look on paper, with a pinned preview.'),
  e('09-07 07:28', 'palette', BLUE, 'A menu made of pictures', 'The main menu becomes artwork, and you pick your roster by face.'),
  e('09-07 13:19', 'volume', BLUE, 'Sound and settings', 'Profile icons, a settings panel, UI sounds, battle sound effects and reduce-motion.'),
  e('09-11 11:57', 'swords', RED, 'Combat rebuilt', 'A turn is now two goes, with movement arrows, the opponent\'s pointer and blow-by-blow fights.'),
  e('09-11 13:20', 'moon', BLUE, 'Dark theme', 'Your settings follow your account, and the game gets a dark theme.'),
  e('09-11 18:42', 'world', BLUE, 'Spanish', 'The whole game, in Spanish.'),
  e('09-11 19:55', 'building-castle', ORANGE, 'Ten kingdoms', 'Build your five-card army from ten different kingdoms.'),
  e('09-12 14:44', 'trophy', GOLD, 'Tournaments', 'Brackets, sign-ups and a tournament page.'),
  e('09-12 16:57', 'wand', PURPLE, 'Abilities', 'Every character gets an ability button, powered by a flexible ability engine.'),
  e('09-12 20:10', 'flame', PURPLE, 'Burn, poison and stun', 'Three status effects that change how a fight plays out.'),
  e('09-12 20:31', 'building-fortress', GREEN, 'Things on the board', 'Structures such as walls, bombs and tornadoes that you can place.'),
  e('09-17 08:27', 'users', ORANGE, 'Battle Royale', 'A four-player mode, with away detection for players who drop.'),
  e('09-21 20:32', 'filter', BLUE, 'Search your roster', 'My Kingdom gets name search, a class filter and sorting.'),
  e('09-22 20:39', 'menu-2', BLUE, 'A new front menu', 'A Play hub, edge-to-edge tiles and artwork that floats as you hover.'),
  e('09-23 11:09', 'movie', PINK, 'A proper match opening', 'Get ready, VS, the board builds tile by tile and the cards land.'),
  e('09-23 11:29', 'book', PINK, 'Comics', 'A Comics page with the story behind the board.'),
  e('09-23 16:32', 'ladder', GOLD, 'Real ratings', 'The tiered ladder gives way to a visible rating and proper matchmaking.'),
  e('09-24 05:54', 'pointer', BLUE, 'Action menu icons', 'Every action has an icon, and a greyed-out button tells you why.'),
  e('09-24 17:47', 'user-plus', ORANGE, 'Friends', 'Player cards, a friends page, and invite cooldowns.'),
  e('09-24 18:04', 'robot', TEAL, 'Ranked bot fallback', 'If no real opponent turns up, a bot steps in.'),
  e('09-24 19:18', 'skull', RED, 'Death animations', 'Every unit that falls now goes down with an animation.'),
  e('09-25 07:50', 'shield', GREEN, 'Smarter Defend', 'Defend can now be aimed at yourself, an ally, an enemy or a structure.'),
  e('09-25 11:04', 'bolt', ORANGE, 'Parry and crit flashes', 'A colour band over the fight scene when a blow is parried or critical.'),
  e('09-26 08:55', 'robot', TEAL, 'Bot levels', 'Beginner, Intermediate and Expert bots.'),
  e('09-28 09:08', 'hourglass', RED, '40-turn limit', 'A match that reaches turn 40 ends in a draw.'),
  e('09-28 20:21', 'flame', PURPLE, 'Stun blocks more', 'A stunned unit can no longer move or defend either, and poison and burn damage became tunable.'),
  e('09-29 13:19', 'book', BLUE, 'Tutorial', 'A first-time interactive lesson, replayable from Settings.'),
  e('09-30 06:15', 'flag', TEAL, 'Feedback and bug reports', 'Send feedback or report a bug straight from Settings.'),
  e('09-30 07:38', 'flag', ORANGE, 'Flags and profiles', 'Country flags, profile descriptions, and card-usage stats.'),
  e('09-30 11:23', 'activity', TEAL, 'Reconnecting', 'A "Reconnecting with opponent..." notice, and the two-missed-turns rule for people who vanish.'),
  e('09-30 13:35', 'stopwatch', RED, 'One clock per turn', 'A single 30-second clock per turn, with ACTIONS LEFT blocks to track it.'),
  e('09-30 15:41', 'sparkles', PURPLE, 'Ten new ability animations', 'Shockwave, lightning, claw slash, meteor, starburst, light pillar and more.'),
  e('09-30 16:46', 'star', GOLD, 'Levels, XP and skins', 'Earn XP and levels, and unlock avatar frames and name colours.'),
  e('09-30 20:26', 'shield-lock', TEAL, 'Chat limits', 'Chat is limited to 3 messages every 5 seconds.'),
  e('10-05 20:12', 'coin', GOLD, 'Shop paused', 'The Shop and Crowns are switched off for now, and Tournaments are back on the menu.'),
  e('10-06 06:28', 'heartbeat', RED, 'New HP bars', 'Flat bars on the token\'s edge, with a damage chunk that drains.'),
  e('10-06 06:37', 'brand-google', BLUE, 'Continue with Google', 'Sign in with your Google account.'),
  e('10-06 06:55', 'activity', GREEN, 'Battle log', 'Icons for each event, bold class-coloured names, and turn dividers.'),
  e('10-07 16:55', 'bell', BLUE, 'Phone notifications', 'Get a push notification on your phone when it matters.'),
  e('10-07 17:30', 'users', ORANGE, 'Royale on phones', 'A mobile overhaul of Battle Royale, with colour-coded opponent HP.'),
  e('10-08 08:00', 'stack-2', BLUE, 'Floating chat and log', 'On desktop, chat and the battle log float beside the board.'),
  e('10-08 09:09', 'shield-half', RED, 'Parries need reach', 'A unit can only parry an attacker it could actually reach.'),
  e('10-09 17:13', 'pointer', BLUE, 'A go, once begun, is finished', 'The action menu stays until you act, Wait or Cancel.'),
  e('10-09 17:21', 'robot', TEAL, 'Smarter bots', 'Bots no longer play abilities that would hurt their own side.'),
  e('10-09 17:37', 'cards', PINK, 'A new card face', 'Cards redrawn from the print reference, with numbers, ability icons and stat icons.'),
  e('10-09 20:32', 'palette', PINK, 'Cleaner card text', 'A text-only ability box that grows with its text, and art cropped for print bleed.'),
  e('10-10 09:55', 'flask-2', TEAL, 'Admin playtest', 'A sandbox where any card or tree can be dropped, with both teams under one hand.'),
  e('10-10 10:00', 'cards', PINK, 'Rounder cards', 'Softer card corners, and My Kingdom tiles zoomed in a little.'),
  e('10-10 21:57', 'palette', PINK, 'Joined-up card stats', 'Movement, range and attack sit flush with each other and the ability box.'),
  e('10-11 08:51', 'zoom-in', BLUE, 'Bigger hover cards', 'On desktop the hovered card is larger and can overlap chat and the log.'),
  e('10-11 09:10', 'sparkles', BLUE, 'Alpha versioning and the update log', 'The game is in alpha, so versions now read 0.x until launch. This log lists everything that has changed.'),
]

/** "1s ago", "34 mins ago", "7h ago", "23 days ago", "3 months ago", "1 year ago". */
export function agoShort(iso: string, lang: 'en' | 'es' = 'en', now = Date.now()): string {
  const sec = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 1000))
  const min = Math.floor(sec / 60), hr = Math.floor(min / 60), day = Math.floor(hr / 24)
  const month = Math.floor(day / 30), year = Math.floor(day / 365)
  const es = lang === 'es'
  const pl = (n: number, one: string, many: string) => (n === 1 ? one : many)
  if (sec < 60) return es ? `hace ${sec} s` : `${sec}s ago`
  if (min < 60) return es ? `hace ${min} min` : `${min} ${pl(min, 'min', 'mins')} ago`
  if (hr < 24) return es ? `hace ${hr} h` : `${hr}h ago`
  if (day < 30) return es ? `hace ${day} ${pl(day, 'día', 'días')}` : `${day} ${pl(day, 'day', 'days')} ago`
  if (day < 365) return es ? `hace ${month} ${pl(month, 'mes', 'meses')}` : `${month} ${pl(month, 'month', 'months')} ago`
  return es ? `hace ${year} ${pl(year, 'año', 'años')}` : `${year} ${pl(year, 'year', 'years')} ago`
}
