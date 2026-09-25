/** The settings icons. Line drawings at 24 units, one stroke weight, so they
 *  sit together as a set rather than as four borrowed glyphs. */
const box = { viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.7,
              strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const }

export const IconGear = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="12" r="3.2" />
    <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.56V21a2 2 0 0 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.55 1.7 1.7 0 0 0-1.88.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.55-1.04H3a2 2 0 0 1 0-4h.1a1.7 1.7 0 0 0 1.55-1.1 1.7 1.7 0 0 0-.34-1.88l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34H9a1.7 1.7 0 0 0 1-1.55V3a2 2 0 0 1 4 0v.1a1.7 1.7 0 0 0 1.04 1.55 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87V9a1.7 1.7 0 0 0 1.55 1H21a2 2 0 0 1 0 4h-.1a1.7 1.7 0 0 0-1.55 1Z" />
  </svg>
)

export const IconSound = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M11 5 6.5 8.5H3v7h3.5L11 19Z" />
    <path d="M15.5 8.8a4.5 4.5 0 0 1 0 6.4" />
    <path d="M18.4 6a8.5 8.5 0 0 1 0 12" />
  </svg>
)

export const IconMusic = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M9 18V6l11-2v12" />
    <circle cx="6.5" cy="18" r="2.5" />
    <circle cx="17.5" cy="16" r="2.5" />
  </svg>
)

export const IconMotion = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M3 12h5l2.5-6 3 12 2.5-6h5" />
  </svg>
)

/** A disc half filled: the one glyph that means "light or dark" without
 *  committing to either, which is what a three-way control needs. */
export const IconTheme = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="12" r="9" />
    <path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor" stroke="none" />
  </svg>
)

/** A globe. The one glyph that means "language" without being a flag -- a
 *  flag is a country, and Spanish is not one country. */
export const IconLang = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="12" r="9" />
    <path d="M3 12h18" />
    <path d="M12 3c2.4 2.6 3.6 5.6 3.6 9s-1.2 6.4-3.6 9c-2.4-2.6-3.6-5.6-3.6-9S9.6 5.6 12 3Z" />
  </svg>
)

/** A clapperboard, near enough at 24 units: a bar over a rectangle. The one
 *  glyph that means "a thing that plays" without being a triangle, which is
 *  already what a play button is and would read as a control. */
export const IconCine = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <rect x="3" y="9" width="18" height="11" rx="2" />
    <path d="M3.6 9 7 4.6M9.6 9 13 4.6M15.6 9 19 4.6" />
    <path d="M3.2 8.2 20 4.2" />
  </svg>
)

export const IconSignOut = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3" />
    <path d="M10 16l-4-4 4-4" />
    <path d="M6 12h10" />
  </svg>
)

export const IconClose = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M6 6l12 12M18 6 6 18" />
  </svg>
)

/** A bell. The one glyph for "something happened while you were elsewhere" --
 *  a friend request, an invite, an acceptance -- without borrowing the
 *  gear's cog or the clapperboard's play-shape. */
export const IconBell = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M6 10a6 6 0 0 1 12 0c0 4.2 1.4 5.7 2 6.4H4c.6-.7 2-2.2 2-6.4Z" />
    <path d="M10 20a2 2 0 0 0 4 0" />
  </svg>
)

/** A person with a plus. Adding a friend is adding a person, not editing a
 *  gear or a list, so the plus sits beside the figure rather than inside it. */
export const IconPersonPlus = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="9" cy="8" r="3.4" />
    <path d="M3.4 20c.6-3.7 3-5.7 5.6-5.7s5 2 5.6 5.7" />
    <path d="M18 7.5v6M15 10.5h6" />
  </svg>
)

/** A plain check. Accepting a request or an invite is answered with the same
 *  mark the rest of the web already means by "yes" -- IconClose already
 *  covers "no". */
export const IconCheck = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M4 12.5 9.5 18 20 6" />
  </svg>
)

export const IconDiscord = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M8.5 5.5c-2 .55-3.3 1.2-3.3 1.2-1.6 3.4-2 6.8-1.8 10.1 0 0 1.5 1.3 4.6 1.6l.9-1.3a8.7 8.7 0 0 1-2.5-1.2s.4.3 1.1.6a12 12 0 0 0 9 0c.7-.3 1.1-.6 1.1-.6a8.7 8.7 0 0 1-2.5 1.2l.9 1.3c3.1-.3 4.6-1.6 4.6-1.6.24-3.7-.5-7.1-1.8-10.1 0 0-1.3-.65-3.3-1.2l-.5 1.1a11.6 11.6 0 0 0-6.6 0Z" />
    <circle cx="9.3" cy="13.3" r="1" fill="currentColor" stroke="none" />
    <circle cx="14.7" cy="13.3" r="1" fill="currentColor" stroke="none" />
  </svg>
)

/** The per-unit action menu's own four (Cancel reuses IconClose above --
 *  same glyph, same meaning). Same 24-unit line style as the rest of this
 *  file; colour comes from the wrapping .actmenu-icon-* class in
 *  styles.css, not from here, so these stay plain and reusable. Stroke
 *  weight for all four in this menu is bumped in styles.css
 *  (.actmenu-icon svg), not here -- this box's own 1.7 stays the shared
 *  default for every other icon in the app. */
export const IconSword = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    {/* Blade, tip to guard -- long enough to dominate the glyph the way an
        actual blade dominates a sword's silhouette. */}
    <path d="M20 4 10 14" />
    {/* The crossguard -- PERPENDICULAR to the blade, not a second stroke
        running parallel to it. That was the whole bug in the first pass at
        this: the old crossguard shared the blade's own slope, so the two
        lines just read as one slightly uneven diagonal stroke with a dot on
        the end -- a checkmark with a blob, not a sword. This one crosses
        the blade at 90 degrees, centred exactly on the blade's own lower
        end, which is what makes a diagonal line read as a hilt. */}
    <path d="M7.2 11.2 12.8 16.8" />
    {/* Grip, continuing the blade's own line past the guard -- short and
        separate from the guard's own stroke rather than overlapping it. */}
    <path d="M10 14 7 17" />
    {/* Pommel. A visible GAP from the grip's own end (not touching it) is
        the other half of the earlier bug -- flush against the grip line
        the two just blurred into one dark smudge at this icon's real
        rendered size (15-17px, see .actmenu-icon in styles.css). */}
    <circle cx="5.5" cy="18.5" r="1.4" fill="currentColor" stroke="none" />
  </svg>
)

export const IconArrowUp = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M12 20V4" />
    <path d="M6 10l6-6 6 6" />
  </svg>
)

export const IconRhombus = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M12 3 21 12 12 21 3 12Z" />
  </svg>
)

/** A pencil, small and plain -- the one glyph this app already reaches for
 *  (see any is-editing hint elsewhere) to say "click here to type" or
 *  "click here to change this" without a word next to it. */
export const IconPencil = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M17.5 3.5a2.12 2.12 0 0 1 3 3L9 18l-4 1 1-4Z" />
    <path d="M14.5 6.5l3 3" />
  </svg>
)

export const IconInstagram = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <rect x="3.5" y="3.5" width="17" height="17" rx="5" />
    <circle cx="12" cy="12" r="4" />
    <circle cx="17" cy="7" r="0.9" fill="currentColor" stroke="none" />
  </svg>
)

/** Admin Mode's own top tab row (AdminPanel.tsx) -- one small glyph per
 *  tab, plain line style matching the rest of this file, colour handled by
 *  the wrapping button's own --tab-tint (see .admintabs in styles.css) so
 *  these stay reusable single-colour outlines rather than baking a hue in. */

/** Two cards in a loose stack -- Cards is the one tab this row can least
 *  afford to make ambiguous. */
export const IconCards = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <rect x="4.5" y="4" width="10" height="14" rx="2" />
    <rect x="9.5" y="7.5" width="10" height="14" rx="2" />
  </svg>
)

/** A small crenellated tower -- Structures are the board's buildings, and a
 *  battlement silhouette reads as "a structure" faster than a plain box
 *  would, at this size. */
export const IconStructure = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M4 21V10h2V7h2v3h2V7h2v3h2V7h2v3h2v11H4Z" />
    <path d="M10 21v-5h4v5" />
  </svg>
)

/** An open book, spine down the middle -- Comics is chapters to read, and a
 *  book says that without borrowing a speech-bubble shape this app already
 *  uses to mean something else (see Ability.tsx's own kwbubble). */
export const IconBook = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M4 5.5c2-1 4.5-1 8 .5 3.5-1.5 6-1.5 8-.5v13c-2-1-4.5-1-8 .5-3.5-1.5-6-1.5-8-.5Z" />
    <path d="M12 6v13" />
  </svg>
)

/** Three plain lines -- the Menu tab edits the LOBBY's menu, so its own
 *  icon is the universal "menu" glyph rather than IconGear, which already
 *  means Settings everywhere else in this app. */
export const IconMenuLines = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M4 7h16M4 12h16M4 17h16" />
  </svg>
)

/** One person, no plus -- IconPersonPlus already means "send a friend
 *  request" on the Friends screen; Users here is the account list, a
 *  plainer ask. */
export const IconPerson = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="8" r="3.6" />
    <path d="M5 20c.7-4 3.4-6 7-6s6.3 2 7 6" />
  </svg>
)

/** A literal ladder -- the ranked ladder this tab's toggle governs, drawn
 *  as plainly as the word itself. */
export const IconLadder = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M7 3v18M17 3v18" />
    <path d="M7 7h10M7 12h10M7 17h10" />
  </svg>
)

/** Two of IconPerson's own heads, side by side -- the header's new door to
 *  the friends list, left of the profile button it sits beside. Jared:
 *  "in mobile version, the friend icon is not centered inside the circle."
 *  Measured with getBBox (stroke included): the two-headed shape's own ink
 *  sits at (11.4, 11.9) in this 24x24 box, not (12, 12) -- small enough to
 *  pass unnoticed at this file's usual 20px render size, obvious at the
 *  16px one .iconbtn shrinks to on a narrow phone. The wrapping <g> nudges
 *  it back onto true centre rather than eyeballing a fix. */
export const IconPeople = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <g transform="translate(0.3, 0.2)">
      <circle cx="9" cy="8" r="3.2" />
      <path d="M3.3 19c.6-3.6 3-5.4 5.7-5.4s5.1 1.8 5.7 5.4" />
      <path d="M15.5 5.3c1.5.4 2.6 1.6 2.6 3.1 0 1.4-.9 2.5-2.2 3" />
      <path d="M15 13.7c2.3.5 4 2.1 4.5 5.3" />
    </g>
  </svg>
)

/* -----------------------------------------------------------------------
 * 0096: the sentence builder's six category glyphs -- one per grammatical
 * role a pill can play (trigger/condition/target/action/detail/duration;
 * see SentenceBuilder.tsx's PILL_CATEGORIES). Same box, same stroke
 * weight as every icon above -- these sit on 13px pills, smaller than
 * this file's usual 15-17px render size, so each one stays to 2-3 strokes
 * rather than trying to hold detail that would just blur at that size.
 * ----------------------------------------------------------------------- */

/** A bolt -- trigger/"when". The one glyph that reads as "something just
 *  happened" without being a clock (a clock says duration, the category
 *  two down from this one). */
export const IconBolt = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M13 3 6 14h5l-1 7 8-12h-5Z" />
  </svg>
)

/** A funnel -- condition/"if". Narrows top to bottom, the way a condition
 *  narrows "every case" down to the ones that pass it. */
export const IconFilter = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M4 4h16l-6 8v6l-4 2v-8Z" />
  </svg>
)

/** A crosshair -- target/"where". A ring with a centre dot, not a full
 *  plus-in-circle -- the tick marks alone already read as "aimed at this"
 *  without needing to cross the whole circle and compete with the dot. */
export const IconCrosshair = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="12" r="7" />
    <circle cx="12" cy="12" r="1.1" fill="currentColor" stroke="none" />
    <path d="M12 2v3M12 19v3M2 12h3M19 12h3" />
  </svg>
)

/** A four-point spark -- action/"what happens". Not a star (too busy at
 *  13px) -- two crossed elongated diamonds, the same glyph a sparkle emoji
 *  reduces to when every curve is stripped out. */
export const IconSpark = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M12 2v7M12 15v7M2 12h7M15 12h7" />
  </svg>
)

/** A price tag -- detail/"which one exactly" (a status, a stat, a
 *  structure -- whichever value finishes the action's sentence). The hole
 *  is what makes a pentagon read as a tag rather than a house. */
export const IconTag = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M11 3H4v7l10 10 7-7Z" />
    <circle cx="7.5" cy="7.5" r="1.2" fill="currentColor" stroke="none" />
  </svg>
)

/** An hourglass -- duration/"for how long". Two triangles pinched at the
 *  waist, the one glyph that means "time passing" without being a clock
 *  face, which would be busier than anything else on a 13px pill. */
export const IconHourglass = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M6 3h12M6 21h12" />
    <path d="M7 3c0 4 3 6 5 6s5-2 5-6M7 21c0-4 3-6 5-6s5 2 5 6" />
  </svg>
)

/** The tournament bracket's own trophy -- Jared: "where's the bracket UI
 *  with a cup in the middle?" (the copy already promises one: see
 *  tourney.blurb/champion/youWon, all "the cup"). A line-drawn cup rather
 *  than an emoji: this set is all single-stroke glyphs at one weight (see
 *  this file's own `box` comment), and a full-colour emoji trophy would
 *  read as a different typeface dropped into the middle of it. */
export const IconTrophy = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M8 3h8v4a4 4 0 0 1-4 4 4 4 0 0 1-4-4V3Z" />
    <path d="M8 4.5a3 3 0 1 0 0 5" />
    <path d="M16 4.5a3 3 0 1 1 0 5" />
    <path d="M12 11v3" />
    <path d="M9.6 17h4.8l.6 3H9Z" />
    <path d="M8 20h8" />
  </svg>
)
