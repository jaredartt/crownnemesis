import { useEffect, useState } from 'react'
import { Match } from './Match'
import { PLAYTEST_IDS, PlaytestMatch } from './PlaytestMatch'
import { supabase } from '../lib/supabase'
import type { Profile } from '../lib/types'

/**
 * Sends a match id to the right screen. An Admin Mode playtest room (0213) has
 * its own local, offline-feeling screen; everything else is the ordinary match
 * screen, rendered at once -- the lookup below only ever swaps a playtest room
 * in (after a reload, which is the one time this tab did not just open it), and
 * is made once, so a rematch (which changes matchId inside Match without
 * unmounting it) is never disturbed.
 */
export function MatchEntry(props: {
  matchId: string
  profile: Profile
  onProfile: (patch: Partial<Profile>) => void
  onLeave: () => void
  onGoTo: (id: string) => void
}) {
  const [playtest, setPlaytest] = useState(PLAYTEST_IDS.has(props.matchId))
  useEffect(() => {
    if (PLAYTEST_IDS.has(props.matchId)) return
    let alive = true
    supabase.from('matches').select('playtest').eq('id', props.matchId).maybeSingle()
      .then(({ data }) => {
        if (alive && data?.playtest) { PLAYTEST_IDS.add(props.matchId); setPlaytest(true) }
      })
    return () => { alive = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  if (playtest) return <PlaytestMatch matchId={props.matchId} onLeave={props.onLeave} />
  return <Match {...props} />
}
