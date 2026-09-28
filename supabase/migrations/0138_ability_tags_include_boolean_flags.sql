-- Found while verifying the calibration run (0137): admin_ability_value()
-- came back EMPTY for the calibration cards even though their burn/poison/
-- stun treatments clearly separated in the data (confirmed with a manual
-- grouping query -- burn +2.9 to +3.9 win-rate points, stun +0.7 to +1.0,
-- poison -4.3 to -5.6, matched across the same 16-point orthogonal stat
-- spread). Root cause: admin_ability_tags() tags 'burns'/'poisons'/'stuns'
-- ONLY from public.card_effects rows (APPLY_STATUS + BURNING/POISON/
-- STUN) -- it never looks at the cards.burns / cards.poisons_adjacent /
-- cards.stuns boolean columns, even though those columns are a real,
-- independently-supported way a card gets the ability (confirmed earlier
-- this session: cn_army() passes them straight onto the unit JSON, no
-- card_effects/abilityScript row needed, and combat honors them directly
-- on basic attacks).
--
-- This isn't just a calibration-card gap -- it already affects a REAL
-- card: himanta has stuns = true and no matching card_effects row, so
-- admin_ability_tags() has been silently blind to it on the live
-- dashboard too. (Checked: no other live card currently has a boolean
-- flag set without a matching card_effects row, so this only changes
-- himanta's tagging among real cards today -- but it's correct for any
-- future card that uses the flag-only path as well.) Verified live after
-- this migration: admin_ability_value(NULL) now includes 'stuns' with
-- cards_with = 1 (himanta), cards_without = 12 -- previously missing
-- entirely -- and the same call scoped to the calibration run now
-- reports burns/stuns/poisons with the with-vs-without deltas that match
-- the manual grouping query.
--
-- Fix: col_tags already reads cards columns for parries/parries_all/
-- crit_boost/double_attack/lifesteal/regen/evasion/anti_poison -- this
-- just adds the three missing ones, tagged to match ce_tags' own naming
-- ('burns', 'poisons', 'stuns'). The outer query is a UNION (not UNION
-- ALL), so a card that somehow had both the flag AND a scripted
-- card_effects row for the same tag would just dedupe, not double-count.
create or replace function public.admin_ability_tags()
 returns table(card_slug text, tag text)
 language sql
 stable
 set search_path to 'public'
as $function$
  with ce_tags as (
    select c.slug,
      case
        when ce.action = 'APPLY_STATUS' and ce.status = 'BURNING' then 'burns'
        when ce.action = 'APPLY_STATUS' and ce.status = 'POISON' then 'poisons'
        when ce.action = 'APPLY_STATUS' and ce.status = 'STUN' then 'stuns'
        when ce.action = 'HEAL' then 'heals'
        when ce.action = 'CREATE_STRUCTURE' then 'summons'
        when ce.action = 'MODIFY_STAT' and ce.stat_name like 'AURA_%' then 'team_aura'
        when ce.action = 'MODIFY_STAT'
             and ce.stat_name in ('HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT')
             and ce.target_selector = 'SELF' then 'self_buff'
        when ce.action = 'MODIFY_STAT'
             and ce.stat_name in ('HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT')
             and ce.target_selector in ('ALL_ALLIES', 'NEARBY_ALLIES') then 'team_buff'
        when ce.action = 'DEAL_DAMAGE' and ce.target_selector in ('ADJACENT_UNITS', 'ALL_ENEMIES', 'ENEMIES_IN_LINE') then 'aoe_damage'
        else null
      end as tag
    from public.card_effects ce
    join public.cards c on c.id = ce.card_id
  ),
  col_tags as (
    select slug, unnest(array[
      case when parries then 'parries' end,
      case when parry_all then 'parries_all' end,
      case when crit_pct is not null and crit_pct > 5 then 'crit_boost' end,
      case when twice_pct is not null and twice_pct > 0 then 'double_attack' end,
      case when lifesteal_pct is not null and lifesteal_pct > 0 then 'lifesteal' end,
      case when regen_pct is not null and regen_pct > 0 then 'regen' end,
      case when evasion_pct is not null and evasion_pct > 0 then 'evasion' end,
      case when vs_poisoned is not null and vs_poisoned <> 0 then 'anti_poison' end,
      case when burns then 'burns' end,
      case when poisons_adjacent then 'poisons' end,
      case when stuns then 'stuns' end
    ]) as tag
    from public.cards
  )
  select slug as card_slug, tag from ce_tags where tag is not null
  union
  select slug as card_slug, tag from col_tags where tag is not null
$function$;
