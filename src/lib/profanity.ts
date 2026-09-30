/**
 * The bad-word check for usernames and profile descriptions.
 *
 * Jared: "a bad word detector... for usernames and descriptions... if it
 * contains a bad word in one of these fields, red words next to it saying
 * the [username/description] can't contain slurs, and it won't let you save
 * until there's no slurs."
 *
 * THE SERVER IS THE AUTHORITY (see 0174_flags_descriptions_slur_filter.sql:
 * a BEFORE INSERT/UPDATE trigger on profiles runs the very same algorithm as
 * cn_slur_check()). This copy exists so the red message can appear while
 * you type instead of after a round trip. The two MUST stay identical --
 * same word lists, same steps -- and the lists below were generated once
 * and pasted into both places. If you edit one, edit the other.
 *
 * How it works, and why it is not just `text.includes(word)`:
 *
 *   Naive substring matching flags "class" (ass), "grape" (rape), "spicy"
 *   (spic), "Scunthorpe" (cunt) -- innocent players locked out of their own
 *   name, which is worse than the problem. So the words come in three tiers:
 *
 *   A  matched as a substring INSIDE a word ("xXfuckerXx", "bullshit").
 *      Only words that essentially never occur inside innocent ones.
 *   B  matched only as a WHOLE word (plural "s" allowed). Short or
 *      ambiguous words: ass, rape, spic, nazi...
 *   C  matched against every letter run together, so "n i g g e r" and
 *      "ni gger" still trip it. Only words that cannot arise by two
 *      innocent words touching ("this hit" would spell "shit" -- so shit is
 *      NOT in this tier).
 *
 *   Before matching, the text is split on camelCase ("MrCunt" -> "Mr Cunt"),
 *   lowercased, accents folded, and checked twice: once as typed and once
 *   with look-alike digits/symbols read as letters (5->s, 1->i, @->a ...).
 *   A run of 3+ single letters ("f-u-c-k", "f u c k") is glued into one word.
 *
 * It is a filter, not a guarantee: creative spellings, other alphabets and
 * words not on the list get through. It catches the common cases.
 */

const A: readonly string[] = [
  'nigger', 'nigga', 'niggah', 'niggaz', 'niglet', 'faggot', 'faggit', 'faggy', 'fagot', 'fuck',
  'fvck', 'phuck', 'fuq', 'shit', 'bitch', 'bastard', 'asshole', 'arsehole', 'dumbass', 'jackass',
  'fatass', 'asswipe', 'cunt', 'penis', 'vagina', 'dildo', 'blowjob', 'handjob', 'rimjob',
  'cumshot', 'pussy', 'whore', 'slutty', 'wanker', 'bollocks', 'bollock', 'dickhead', 'cocksucker',
  'douche', 'molest', 'pedophile', 'paedophile', 'pedophilia', 'paedophilia', 'pedobear', 'jizz',
  'orgasm', 'masturbate', 'masturbation', 'clitoris', 'butthole', 'sexting', 'porn', 'hentai',
  'onlyfans', 'hitler', 'neonazi', 'swastika', 'kkk', 'beaner', 'wetback', 'jigaboo',
  'porchmonkey', 'towelhead', 'raghead', 'tranny', 'trannie', 'shemale', 'sodomite', 'mongoloid',
  'gilipollas', 'hijueputa', 'hijoputa', 'putain', 'connard', 'connasse', 'salope', 'encule',
  'bougnoule', 'youpin', 'arschloch', 'hurensohn', 'wichser', 'schlampe', 'missgeburt', 'scheisse',
  'scheiss', 'cazzo', 'stronzo', 'puttana', 'vaffanculo', 'minchia', 'coglione', 'caralho',
  'buceta', 'arrombado', 'filhodaputa', 'pizda', 'orospu', 'mierda', 'bullshit',
]
const B: readonly string[] = [
  'ass', 'asses', 'arse', 'arses', 'dick', 'dicks', 'cock', 'cocks', 'twat', 'prick', 'sex',
  'sexy', 'tits', 'boob', 'boobs', 'boobies', 'nipple', 'clit', 'vulva', 'anus', 'anal', 'cum',
  'semen', 'boner', 'horny', 'fap', 'fapping', 'wank', 'wanking', 'slut', 'sluts', 'rape', 'raped',
  'raping', 'rapes', 'rapist', 'rapists', 'pedo', 'nazi', 'nazis', 'chink', 'chinks', 'kike',
  'kyke', 'spic', 'spick', 'gook', 'coon', 'coons', 'paki', 'jap', 'japs', 'wop', 'dago', 'tranny',
  'fag', 'fags', 'faggots', 'dyke', 'lesbo', 'retard', 'retards', 'retarded', 'retardo', 'spaz',
  'spastic', 'tard', 'autist', 'sperg', 'mong', 'kys', 'milf', 'hoe', 'hoes', 'cuck', 'nudes',
  'puta', 'puto', 'putas', 'putos', 'pendejo', 'pendeja', 'pendejos', 'cabron', 'cabrona', 'joder',
  'verga', 'chingada', 'chingar', 'chinga', 'chingado', 'culero', 'zorra', 'maricon', 'marica',
  'maricones', 'capullo', 'hdp', 'ctm', 'merde', 'batard', 'nique', 'niquer', 'ntm', 'fdp', 'pute',
  'negre', 'neger', 'kanake', 'spast', 'nutte', 'fick', 'ficken', 'ficker', 'fickt', 'arsch',
  'fotze', 'merda', 'troia', 'frocio', 'porra', 'viado', 'cuzao', 'blyat', 'blyad', 'cyka',
  'pidor', 'pidar', 'pidr', 'huy', 'ebat', 'mudak', 'amk', 'polack',
]
const C: readonly string[] = [
  'nigger', 'nigga', 'faggot', 'fuck', 'whitepower', 'whitepride', 'killyourself', 'killurself',
  'gasthejews', 'heilhitler', 'siegheil',
]
/** Innocent words that contain a tier-A word. Removed before matching. */
const ALLOW: readonly string[] = [
  'scunthorpe', 'penistone',
]

const FOLD_FROM = 'áàäâãåéèëêíìïîóòöôõøúùüûñçýÿ'
const FOLD_TO = 'aaaaaaeeeeiiiioooooouuuuncyy'
const LEET_FROM = '013457@$!'
const LEET_TO = 'oieastasi'

const B_SET = new Set(B)

function translate(s: string, from: string, to: string): string {
  let out = ''
  for (const ch of s) {
    const i = from.indexOf(ch)
    out += i === -1 ? ch : to[i]
  }
  return out
}

export function containsSlur(text: string | null | undefined): boolean {
  if (!text || !text.trim()) return false
  let s = text
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .replace(/([A-Z])([A-Z][a-z])/g, '$1 $2')
  s = translate(s.toLowerCase(), FOLD_FROM, FOLD_TO)
  for (const leet of [false, true]) {
    const t = (leet ? translate(s, LEET_FROM, LEET_TO) : s).replace(/[^a-z]+/g, ' ').trim()
    if (!t) continue
    const toks = t.split(' ')
    const words: string[] = []
    let run = ''
    for (const tok of toks) {
      if (tok.length === 1) { run += tok; continue }
      if (run.length >= 3) words.push(run)
      run = ''
      words.push(tok)
    }
    if (run.length >= 3) words.push(run)
    for (const raw of words) {
      let tok = raw
      for (const ok of ALLOW) tok = tok.split(ok).join('')
      for (const bad of A) if (tok.includes(bad)) return true
      if (B_SET.has(tok)) return true
      if (tok.endsWith('s') && B_SET.has(tok.slice(0, -1))) return true
    }
    const compact = toks.join('')
    for (const bad of C) if (compact.includes(bad)) return true
  }
  return false
}

/** Whitespace-separated words, the way the server counts them. */
export function wordCount(text: string): number {
  const t = text.trim()
  return t === '' ? 0 : t.split(/\s+/).length
}

export const DESCRIPTION_MAX_WORDS = 100
