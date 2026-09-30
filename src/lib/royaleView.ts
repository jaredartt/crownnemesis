import type {
  MatchState, Obstacle, RoyaleMatchState, RoyaleUnit, Side, Unit,
} from './types'

/**
 * Battle Royale on 1v1's board.
 *
 * 0179 made Battle Royale run 1v1's own rules (its Postgres functions are
 * generated from 1v1's), so what it needs from the client is no longer a
 * sibling of the board -- it is the SAME board, fed the same kind of state.
 * Board.tsx knows two sides, and everything it draws and lights up is decided
 * by "is this unit mine / is it the other side's". A royale table has four
 * seats, but for whoever is looking it is still exactly that question: your
 * units (blue) against everyone else's (red). Nobody has team play here, so
 * "everyone else" behaves as one side for every rule the board asks about --
 * targets, counters, who may be struck.
 *
 * So this is the only translation: seat numbers in, 'host'/'guest' out, for
 * the units, the turn, the structures' owners, whoever raised a guard, the
 * tornado's open decision and the mist. Nothing is decided here, and nothing
 * comes back the other way -- every click still goes to the server by its
 * real seat and unit id.
 *
 * `pov` is the seat being looked from: yours while you play; the one being
 * followed by a spectator or a player who is out. Seats 0 and 1 hold the top
 * of the board, so they are 'host' and Board turns the picture half a turn for
 * them (the same flip 1v1's host gets); seats 2 and 3 are 'guest' and already
 * sit at the bottom.
 */
export function royaleSides(pov: number | null) {
  const mine: Side = pov !== null && pov < 2 ? 'host' : 'guest'
  const other: Side = mine === 'host' ? 'guest' : 'host'
  /** The side a seat is drawn as. */
  const of = (seat: number | string | null | undefined): Side =>
    seat !== null && seat !== undefined && pov !== null && Number(seat) === pov ? mine : other
  return { mine, other, of }
}

export function royaleAsMatch(
  state: RoyaleMatchState,
  pov: number | null,
  ended: { finished: boolean; draw: boolean },
): MatchState {
  const { of, mine } = royaleSides(pov)

  const units: Unit[] = state.units.map((u: RoyaleUnit) => ({
    ...u,
    owner: of(u.owner),
    defendedBy: u.defendedBy == null ? u.defendedBy : of(u.defendedBy as unknown as number),
  }) as Unit)

  const obstacles: Obstacle[] = (state.obstacles ?? []).map((o) => {
    const raw = o as unknown as { owner?: number | string | null; defendedBy?: number | string | null }
    return {
      ...o,
      ...(raw.owner == null ? {} : { owner: of(raw.owner) }),
      ...(raw.defendedBy == null ? {} : { defendedBy: of(raw.defendedBy) }),
    } as Obstacle
  })

  let mist: MatchState['mist']
  if (state.mist) {
    mist = {}
    for (const [seat, m] of Object.entries(state.mist)) {
      const s = of(Number(seat))
      // Several seats share the "other" side; the longest-running one shows.
      if (!mist[s] || m.t > (mist[s]?.t ?? 0)) mist[s] = m
    }
  }

  const pending = state.pending
    ? { ...state.pending, side: of(state.pending.side) }
    : null

  const winner: MatchState['winner'] = !ended.finished
    ? null
    : ended.draw || state.winnerSeat == null
      ? 'draw'
      : of(state.winnerSeat)

  return {
    v: state.v,
    board: state.board,
    phase: 'battle',
    ready: { host: true, guest: true },
    obstacles,
    pending,
    turn: state.turn === null ? mine : of(state.turn),
    turnNumber: state.turnNumber,
    acts: state.acts,
    active: state.active ?? null,
    undo: state.undo ?? null,
    units,
    log: state.log,
    mist,
    winner,
    staleRounds: state.staleRounds,
    roundDmg: state.roundDmg,
    fx: state.fx,
  }
}
