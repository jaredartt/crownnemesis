-- 0218: per-unit damage tracking and the card-balance report (Admin Mode -> Balance).
--
-- unit_match_stats keeps, for each unit in each real match, the damage it dealt,
-- the damage it took, the HP it healed and whether it died. cn_track_unit_stats()
-- fills it from every board change (an AFTER UPDATE on matches), by diffing the
-- units' HP before and after:
--   * damage TAKEN is exact (HP lost).
--   * damage DEALT is exact for attacks and counters, using the per-blow log the
--     engine already writes (state.fx.swings), scaled down if a blow overkilled.
--     Damage left unexplained (abilities, area effects) is credited to the single
--     unit whose `acted` flipped in that update; poison and burn count as taken only.
--   * healing is credited to the acting unit's team gain in that update.
-- It is wrapped so it can never break a match, and skips simulations and playtests.
-- Only matches played after this migration have rows: older ones show a dash.
--
-- admin_card_balance(mode, days) joins that with match_deploy (who fielded what)
-- over FINISHED, human, non-playtest matches. Win rate, pick rate and turns use
-- every mode selected; the damage columns are RANKED only.
create table if not exists public.unit_match_stats (
  match_id uuid not null,
  unit_id  text not null,
  slug     text,
  owner    text,
  dealt    integer not null default 0,
  taken    integer not null default 0,
  healed   integer not null default 0,
  died     boolean not null default false,
  primary key (match_id, unit_id)
);
alter table public.unit_match_stats enable row level security;  -- no policy: read only through admin_card_balance()

create or replace function public.cn_track_unit_stats() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare v_old jsonb := old.state; v_new jsonb := new.state;
begin
  begin
    if v_old->'units' is null or v_new->'units' is null then return null; end if;
    with ou as (
      select u->>'id' id, u->>'slug' slug, u->>'owner' owner, (u->>'hp')::int hp,
             coalesce((u->>'acted')::boolean, false) acted
        from jsonb_array_elements(v_old->'units') u),
    nu as (
      select u->>'id' id, (u->>'hp')::int hp, coalesce((u->>'acted')::boolean, false) acted
        from jsonb_array_elements(v_new->'units') u),
    chg as (
      select ou.id, ou.slug, ou.owner,
             greatest(ou.hp - greatest(coalesce(nu.hp, 0), 0), 0) lost,
             case when nu.id is not null then greatest(nu.hp - ou.hp, 0) else 0 end gained,
             (nu.id is null) died,
             (nu.id is not null and nu.acted and not ou.acted) did_act
        from ou left join nu using (id)),
    sw as (
      select s->>'by' by, s->>'at' tgt, coalesce((s->>'dmg')::numeric, 0) dmg
        from jsonb_array_elements(
               case when (v_new #>> '{fx,seq}') is distinct from (v_old #>> '{fx,seq}')
                    then coalesce(v_new #> '{fx,swings}', '[]'::jsonb) else '[]'::jsonb end) s
       where s->>'k' = 'hit'),
    ex as (select tgt, sum(dmg) ex from sw group by tgt),
    byunit as (
      select sw.by id, sum(sw.dmg * least(1.0, c.lost::numeric / nullif(e.ex, 0))) dealt
        from sw join ex e on e.tgt = sw.tgt join chg c on c.id = sw.tgt group by sw.by),
    actor as (
      select id, owner from chg where did_act and (select count(*) from chg where did_act) = 1),
    unexpl as (
      select c.id, c.owner, c.lost - least(c.lost, coalesce(e.ex, 0)) rest
        from chg c left join ex e on e.tgt = c.id
       where c.lost > least(c.lost, coalesce(e.ex, 0))),
    ab as (
      select a.id, sum(u.rest) dealt from actor a join unexpl u on u.owner <> a.owner group by a.id),
    dealt_all as (
      select id, sum(dealt) dealt from (select id, dealt from byunit union all select id, dealt from ab) z group by id),
    heal as (
      select a.id, sum(c.gained) healed from actor a join chg c on c.owner = a.owner and c.gained > 0 group by a.id),
    fin as (
      select c.id, c.slug, c.owner, c.lost taken, c.died,
             round(coalesce(d.dealt, 0))::int dealt, coalesce(h.healed, 0)::int healed
        from chg c left join dealt_all d on d.id = c.id left join heal h on h.id = c.id)
    insert into public.unit_match_stats as s (match_id, unit_id, slug, owner, dealt, taken, healed, died)
    select new.id, f.id, f.slug, f.owner, f.dealt, f.taken, f.healed, f.died from fin f
     where f.dealt > 0 or f.taken > 0 or f.healed > 0 or f.died
    on conflict (match_id, unit_id) do update
      set dealt = s.dealt + excluded.dealt, taken = s.taken + excluded.taken,
          healed = s.healed + excluded.healed, died = s.died or excluded.died;
  exception when others then
    null; -- stats must never be able to break a match
  end;
  return null;
end $function$;

create or replace trigger cn_track_unit_stats after update of state on public.matches
  for each row when (new.state is distinct from old.state and not coalesce(new.is_sim, false) and not coalesce(new.playtest, false))
  execute function public.cn_track_unit_stats();

create or replace function public.admin_card_balance(p_mode text default 'all', p_days integer default 0)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v jsonb; v_tot jsonb;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  with g as (   -- one row per human-fielded card per finished match
    select d.match_id, d.side, d.user_id, e->>'slug' slug, m.ranked, m.winner,
           (m.state->>'turnNumber')::int turns, m.updated_at at
      from public.match_deploy d
      join public.matches m on m.id = d.match_id
      cross join lateral jsonb_array_elements(d.units) e
     where m.status = 'finished' and not coalesce(m.is_sim, false) and not coalesce(m.playtest, false)
       and d.user_id is not null and e->>'slug' is not null
       and (p_days <= 0 or m.updated_at >= now() - make_interval(days => p_days))
  ), f as (     -- the mode filter for everything except damage
    select * from g where p_mode = 'all' or (p_mode = 'ranked' and ranked) or (p_mode = 'casual' and not coalesce(ranked, false))
  ), teams as (select count(distinct (match_id, side)) n, count(distinct user_id) users from f),
  tracked as (select distinct match_id from public.unit_match_stats),
  dmg as (      -- ranked only, and only matches the tracker saw
    select g.slug, count(*) games, coalesce(avg(s.dealt), 0) dealt, coalesce(avg(s.taken), 0) taken,
           coalesce(avg(s.healed), 0) healed, coalesce(avg(case when s.died then 1 else 0 end), 0) died
      from g
      join tracked t on t.match_id = g.match_id
      left join public.unit_match_stats s on s.match_id = g.match_id and s.slug = g.slug and s.owner = g.side
     where g.ranked
     group by g.slug
  ), agg as (
    select f.slug, count(*) games,
           count(*) filter (where f.winner = f.side) wins,
           count(*) filter (where f.winner in ('host','guest') and f.winner <> f.side) losses,
           count(distinct f.user_id) players,
           avg(f.turns) turns
      from f group by f.slug
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'slug', a.slug, 'name', coalesce(c.name, a.slug), 'role', c.role,
      'games', a.games, 'wins', a.wins, 'losses', a.losses,
      'win_rate', case when a.wins + a.losses > 0 then round(100.0 * a.wins / (a.wins + a.losses), 1) end,
      'players', a.players,
      'player_share', case when t.users > 0 then round(100.0 * a.players / t.users, 1) end,
      'pick_rate', case when t.n > 0 then round(100.0 * a.games / t.n, 1) end,
      'avg_turns', round(a.turns::numeric, 1),
      'ranked_games', coalesce(d.games, 0),
      'avg_dealt', case when d.games > 0 then round(d.dealt::numeric, 1) end,
      'avg_taken', case when d.games > 0 then round(d.taken::numeric, 1) end,
      'avg_healed', case when d.games > 0 then round(d.healed::numeric, 1) end,
      'survival', case when d.games > 0 then round(100.0 * (1 - d.died)::numeric, 1) end
    ) order by a.games desc, a.slug), '[]'::jsonb)
    into v
    from agg a cross join teams t
    left join public.cards c on c.slug = a.slug
    left join dmg d on d.slug = a.slug;
  select jsonb_build_object(
    'teams', (select n from (select count(distinct (match_id, side)) n from (
                select d.match_id, d.side from public.match_deploy d join public.matches m on m.id = d.match_id
                 where m.status = 'finished' and not coalesce(m.is_sim, false) and not coalesce(m.playtest, false) and d.user_id is not null
                   and (p_days <= 0 or m.updated_at >= now() - make_interval(days => p_days))
                   and (p_mode = 'all' or (p_mode = 'ranked' and m.ranked) or (p_mode = 'casual' and not coalesce(m.ranked, false)))) z) q),
    'tracked_matches', (select count(*) from (select distinct match_id from public.unit_match_stats) y)
  ) into v_tot;
  return jsonb_build_object('cards', v, 'totals', v_tot);
end $function$;

revoke all on function public.admin_card_balance(text,integer) from public, anon;
grant execute on function public.admin_card_balance(text,integer) to authenticated;

revoke all on function public.cn_track_unit_stats() from public, anon, authenticated;
