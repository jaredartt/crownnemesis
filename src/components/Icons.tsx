import { Ti } from './Ti'

/* Every icon in the game is a Tabler icon (https://tabler.io/icons, MIT) -- see
   Ti.tsx. Same names and props as before, so no caller changed; colours still
   come from the CSS around each one (currentColor). The three that were drawn
   solid (the bot levels' bolt and flame, the crown) use Tabler's filled set. */
type P = { className?: string }

export const IconGear = (p: P) => <Ti name="settings" {...p} />
export const IconSound = (p: P) => <Ti name="volume" {...p} />
export const IconMusic = (p: P) => <Ti name="music" {...p} />
export const IconMotion = (p: P) => <Ti name="activity" {...p} />
export const IconTheme = (p: P) => <Ti name="contrast-2" {...p} />
export const IconLang = (p: P) => <Ti name="world" {...p} />
export const IconCine = (p: P) => <Ti name="movie" {...p} />
export const IconSignOut = (p: P) => <Ti name="logout" {...p} />
export const IconClose = (p: P) => <Ti name="x" {...p} />
export const IconBell = (p: P) => <Ti name="bell" {...p} />
export const IconPersonPlus = (p: P) => <Ti name="user-plus" {...p} />
export const IconCheck = (p: P) => <Ti name="check" {...p} />
export const IconDiscord = (p: P) => <Ti name="brand-discord" {...p} />
export const IconSword = (p: P) => <Ti name="sword" {...p} />
export const IconArrowUp = (p: P) => <Ti name="arrow-up" {...p} />
export const IconRhombus = (p: P) => <Ti name="diamond" {...p} />
export const IconPencil = (p: P) => <Ti name="pencil" {...p} />
export const IconInstagram = (p: P) => <Ti name="brand-instagram" {...p} />
export const IconCards = (p: P) => <Ti name="cards" {...p} />
export const IconStructure = (p: P) => <Ti name="building-fortress" {...p} />
export const IconBook = (p: P) => <Ti name="book" {...p} />
export const IconMenuLines = (p: P) => <Ti name="menu-2" {...p} />
export const IconPerson = (p: P) => <Ti name="user" {...p} />
export const IconLadder = (p: P) => <Ti name="ladder" {...p} />
export const IconPeople = (p: P) => <Ti name="users" {...p} />
export const IconBolt = (p: P) => <Ti name="bolt" {...p} />
export const IconFilter = (p: P) => <Ti name="filter" {...p} />
export const IconCrosshair = (p: P) => <Ti name="crosshair" {...p} />
export const IconSpark = (p: P) => <Ti name="stars" {...p} />
export const IconTag = (p: P) => <Ti name="tag" {...p} />
export const IconHourglass = (p: P) => <Ti name="hourglass" {...p} />
export const IconTrophy = (p: P) => <Ti name="trophy" {...p} />
export const IconSparkle = (p: P) => <Ti name="sparkles" {...p} />
export const IconFlag = (p: P) => <Ti name="flag" {...p} />
export const IconChart = (p: P) => <Ti name="chart-bar" {...p} />
export const IconLevelBeginner = (p: P) => <Ti name="plant" {...p} />
export const IconLevelMid = (p: P) => <Ti name="bolt" filled {...p} />
export const IconLevelExpert = (p: P) => <Ti name="flame" filled {...p} />
export const IconPalette = (p: P) => <Ti name="palette" {...p} />
export const IconFrame = (p: P) => <Ti name="circle-dot" {...p} />
export const IconCrown = (p: P) => <Ti name="crown" filled {...p} />
