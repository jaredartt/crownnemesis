-- 0050_port_existing_cards.sql
--
-- Ports every active card's existing passive columns, and ONE existing
-- ability, into card_effects rows through the engine 0049 built, then
-- verifies -- card by card, column by column -- that the compiler
-- reproduces the exact value the card already had. A mismatch aborts the
-- whole migration (it runs inside one transaction), so this can never leave
-- a card silently retuned.
--
-- PASSIVES PORTED (12 cards, 13 rows): dereo, miah, stelaris (the three
-- royal auras), lium (parry_all), himanta (slippery + twice_pct), dorme
-- (parries), umiro (swamps), sarrave (poisons_adjacent), thalgrim
-- (vs_poisoned), nyxara (lifesteal_pct), wuzu (regen_pct), zephyra (stuns).
-- Every one of these becomes a PASSIVE/MODIFY_STAT row with target_selector
-- 'SELF' -- the compiler (cn_compile_card_effects) never reads
-- target_selector for a PASSIVE row, but the column is NOT NULL, so 'SELF'
-- is the honest placeholder: a passive is a fact about the card itself.
--
-- ABILITY CONVERTED (1 card): Dione & Grifo's aoe_adjacent -> 'scripted',
-- ON_ABILITY/ADJACENT_UNITS/DEAL_DAMAGE, value 15. This is the ONLY one of
-- the four candidate ability_kinds (aoe_adjacent/heal_any/poison_hit/
-- line_burn) converted in this pass. The other three are DELIBERATELY LEFT
-- ON THEIR LEGACY BRANCH -- see the note below the assertions for why.
--
-- NOT PORTED AT ALL: mako/fey/lumea (summon) and eva (mist) -- SUMMON_OBJECT
-- is a documented no-op in cn_effect_apply_action and there is no MIST/
-- stealth-zone action in the vocabulary, so these three legacy ability_kinds
-- stay exactly as they are, untouched, on their existing hard-coded cn_ability
-- branches.

do $$
declare
  v_id uuid; v_row public.cards;
begin

  -- ---- dereo: aura resist/knight/20 ---------------------------------------
  select id into v_id from public.cards where slug = 'dereo';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'AURA_RESIST_KNIGHT', 20);
  select * into v_row from public.cards where id = v_id;
  if v_row.aura_kind <> 'resist' or v_row.aura_class <> 'knight' or v_row.aura_pct <> 20 then
    raise exception 'dereo aura mismatch after port: % % %', v_row.aura_kind, v_row.aura_class, v_row.aura_pct;
  end if;

  -- ---- miah: aura bonus/mage/20 -------------------------------------------
  select id into v_id from public.cards where slug = 'miah';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'AURA_BONUS_MAGE', 20);
  select * into v_row from public.cards where id = v_id;
  if v_row.aura_kind <> 'bonus' or v_row.aura_class <> 'mage' or v_row.aura_pct <> 20 then
    raise exception 'miah aura mismatch after port: % % %', v_row.aura_kind, v_row.aura_class, v_row.aura_pct;
  end if;

  -- ---- stelaris: aura resist_effects/50 -----------------------------------
  select id into v_id from public.cards where slug = 'stelaris';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'AURA_RESIST_EFFECTS', 50);
  select * into v_row from public.cards where id = v_id;
  if v_row.aura_kind <> 'resist_effects' or v_row.aura_class is not null or v_row.aura_pct <> 50 then
    raise exception 'stelaris aura mismatch after port: % % %', v_row.aura_kind, v_row.aura_class, v_row.aura_pct;
  end if;

  -- ---- lium: parry_all ----------------------------------------------------
  select id into v_id from public.cards where slug = 'lium';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'PARRY_ALL', null);
  select * into v_row from public.cards where id = v_id;
  if v_row.parry_all is not true then
    raise exception 'lium parry_all mismatch after port: %', v_row.parry_all;
  end if;

  -- ---- himanta: slippery + twice_pct 25 -----------------------------------
  select id into v_id from public.cards where slug = 'himanta';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value) values
    (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'SLIPPERY', null),
    (v_id, 1, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'TWICE_PCT', 25);
  select * into v_row from public.cards where id = v_id;
  if v_row.slippery is not true or v_row.twice_pct <> 25 then
    raise exception 'himanta mismatch after port: % %', v_row.slippery, v_row.twice_pct;
  end if;

  -- ---- dorme: parries -------------------------------------------------------
  select id into v_id from public.cards where slug = 'dorme';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'PARRIES', null);
  select * into v_row from public.cards where id = v_id;
  if v_row.parries is not true then
    raise exception 'dorme parries mismatch after port: %', v_row.parries;
  end if;

  -- ---- umiro: swamps --------------------------------------------------------
  select id into v_id from public.cards where slug = 'umiro';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'SWAMPS', null);
  select * into v_row from public.cards where id = v_id;
  if v_row.swamps is not true then
    raise exception 'umiro swamps mismatch after port: %', v_row.swamps;
  end if;

  -- ---- sarrave: poisons_adjacent --------------------------------------------
  select id into v_id from public.cards where slug = 'sarrave';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'POISONS_ADJACENT', null);
  select * into v_row from public.cards where id = v_id;
  if v_row.poisons_adjacent is not true then
    raise exception 'sarrave poisons_adjacent mismatch after port: %', v_row.poisons_adjacent;
  end if;

  -- ---- thalgrim: vs_poisoned 25 ----------------------------------------------
  select id into v_id from public.cards where slug = 'thalgrim';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'VS_POISONED_BONUS', 25);
  select * into v_row from public.cards where id = v_id;
  if v_row.vs_poisoned <> 25 then
    raise exception 'thalgrim vs_poisoned mismatch after port: %', v_row.vs_poisoned;
  end if;

  -- ---- nyxara: lifesteal_pct 100 ----------------------------------------------
  select id into v_id from public.cards where slug = 'nyxara';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'LIFESTEAL_PCT', 100);
  select * into v_row from public.cards where id = v_id;
  if v_row.lifesteal_pct <> 100 then
    raise exception 'nyxara lifesteal_pct mismatch after port: %', v_row.lifesteal_pct;
  end if;

  -- ---- wuzu: regen_pct 5 -------------------------------------------------------
  select id into v_id from public.cards where slug = 'wuzu';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'REGEN_PCT', 5);
  select * into v_row from public.cards where id = v_id;
  if v_row.regen_pct <> 5 then
    raise exception 'wuzu regen_pct mismatch after port: %', v_row.regen_pct;
  end if;

  -- ---- zephyra: stuns -----------------------------------------------------------
  select id into v_id from public.cards where slug = 'zephyra';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name, value)
  values (v_id, 0, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'STUNS_ON_HIT', null);
  select * into v_row from public.cards where id = v_id;
  if v_row.stuns is not true then
    raise exception 'zephyra stuns mismatch after port: %', v_row.stuns;
  end if;

  -- ==========================================================================
  -- Dione & Grifo: aoe_adjacent -> scripted / ON_ABILITY / ADJACENT_UNITS /
  -- DEAL_DAMAGE / 15. This is the one ability conversion in this migration.
  --
  -- WHY THE OTHER THREE (heal_any/poison_hit/line_burn) ARE NOT CONVERTED:
  -- every one of those legacy branches enforces `v_dist > rmax` (and, for
  -- heal_any/poison_hit, cn_los_clear) before it does anything -- a player
  -- cannot heal, poison or line-burn a target standing further away than the
  -- card's own range stat, or through a tree. cn_run_effects/
  -- cn_resolve_targets/cn_effect_apply_action carry NO such range or
  -- line-of-sight check for a targeted trigger today -- ON_ABILITY's
  -- 'scripted' branch in cn_ability calls cn_run_effects unconditionally, so
  -- a converted card would let a player designate ANY target on the board,
  -- at ANY distance, through ANY obstacle, and still have it resolve. That
  -- is a live gameplay/balance regression, not a refactor, and it is exactly
  -- the kind of silently-dropped behavior this project's #1 rule exists to
  -- catch. aoe_adjacent is the one candidate this does not apply to: its
  -- range IS the ADJACENT_UNITS selector's fixed cheb()=1, which is baked
  -- into cn_resolve_targets the same way it was baked into the old branch,
  -- so nothing is lost by converting it. Sinie, Velmor and Ashvar are left
  -- on their original, fully-guarded hard-coded branches -- see this
  -- migration's header and the final report for this named plainly as a
  -- deliberate scope reduction, not an oversight.
  -- ==========================================================================
  select id into v_id from public.cards where slug = 'dione-grifo';
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
  values (v_id, 0, 'ON_ABILITY', 'ADJACENT_UNITS', 'DEAL_DAMAGE', 15);

  update public.cards set ability_kind = 'scripted' where id = v_id;

  select * into v_row from public.cards where id = v_id;
  if v_row.ability_kind <> 'scripted' or v_row.ability_n <> 15 then
    raise exception 'dione-grifo mismatch after port: % %', v_row.ability_kind, v_row.ability_n;
  end if;

end
$$;
