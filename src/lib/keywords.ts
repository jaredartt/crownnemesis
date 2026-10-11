/**
 * The purple words, and where their numbers come from.
 *
 * THERE IS NO KEYWORD TABLE, and that is the whole design. The roster spec
 * already settled this in one line -- "text in parentheses is the tooltip
 * number, not part of the description; the word immediately before it is the
 * purple keyword" -- and 0023 wrote the spec's sentences into the database
 * verbatim, parentheses and all. So the ability text is already marked up:
 *
 *     "Slightly (5%->10%) increased parry and crit rates."
 *      ^^^^^^^^  ^^^^^^^^
 *      keyword   its number
 *
 * A hand-kept list of vague words would have to exist twice over -- once per
 * language -- and would have to be edited every time Jared retunes a card in
 * the admin panel, which is a deploy to change a number that lives in a row.
 * Reading the marks out of the sentence costs nothing, works in Spanish
 * without knowing any Spanish, and lets a new card arrive with its own
 * tooltips already attached.
 *
 * THE ONE EXCEPTION is a parenthetical at the END of a sentence. Lumea's
 * "choose where to throw them (15s limit)." would make a keyword of "them",
 * which is nonsense; in every card that really means a keyword the number sits
 * mid-sentence, qualifying the word in front of it. So a parenthetical with
 * nothing after it but a full stop is left exactly as written, and reads as
 * the aside it is. (A bracket with no spaces in it -- "(5'5)", "(15%)" -- is a
 * figure, not an aside, so it still marks its word at the end of a sentence.)
 *
 * A consequence worth knowing: the two languages do not always mark the same
 * word, because the number does not always sit in the same place. English says
 * "Slight (25%) chance to strike twice" and Spanish says "Leve probabilidad
 * (25%) de atacar dos veces", so one highlights "Slight" and the other
 * "probabilidad". Both are the word the number qualifies in their own
 * sentence, which is the only thing this can promise.
 */

export interface Bit {
  /** The words. */
  text: string
  /** The number behind them, when this bit is a keyword. */
  note?: string
}

/**
 * A word, optional spaces, then a bracketed note. The word is matched with
 * unicode classes rather than \w, because "levemente" is fine but "envenenado"
 * is not the only thing Spanish will throw at this and accented letters must
 * not split a word in half.
 *
 * The note is capped at 60 characters: past that it is prose somebody put in
 * brackets, not a number, and a tooltip is the wrong shape for it.
 */
const MARK = /([\p{L}\p{N}][\p{L}\p{N}'’\-]*)[  ]*\(([^()]{1,60})\)/gu

/** Nothing after it but the end of a sentence. See the note above. */
const TRAILING = /^\s*(?:[.!?…]|$)/

export function readAbility(text: string | null | undefined): Bit[] {
  if (!text) return []
  const out: Bit[] = []
  let at = 0
  let m: RegExpExecArray | null
  MARK.lastIndex = 0
  while ((m = MARK.exec(text))) {
    // An aside, left alone -- unless the bracket is a bare figure like "(5'5)" or
    // "(15%)" (no spaces), which is a number for the word before it, full stop or not.
    if (TRAILING.test(text.slice(MARK.lastIndex)) && /\s/.test(m[2].trim())) continue
    const word = m[1]
    const wordAt = m.index
    if (wordAt > at) out.push({ text: text.slice(at, wordAt) })
    out.push({ text: word, note: m[2].trim() })
    at = MARK.lastIndex
  }
  if (at < text.length) out.push({ text: text.slice(at) })
  return out.length ? out : [{ text }]
}

/** Is there anything in here to point at? Used to keep a plain sentence out of
 *  the interactive path entirely rather than wrapping every word in nothing. */
export const hasKeywords = (text: string | null | undefined) =>
  readAbility(text).some((b) => b.note !== undefined)
