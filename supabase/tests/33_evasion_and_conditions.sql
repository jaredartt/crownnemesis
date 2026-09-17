-- 0059: EVASION_PCT (a real new roll in cn_attack -- no damage, no counter,
-- no chain, when it lands) and the flat self.hp/target.hp condition fields.
-- SLIPPERY/FLIES staying valid stat_names (backward compat for Himanta's
-- existing row and any card still carrying `flies`) is also checked here,
-- since this is the migration that would have been the one to break it.

\set ON_ERROR_STOP on
\pset pager off

-- ---- schema: EVASION_PCT accepted, SLIPPERY/FLIES still accepted --------
do $$
declare v_card uuid;
begin
  select id into v_card from public.cards where slug = 'ashvar';
  perform t_ok(v_card is not null, 'ashvar exists to test against');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, stat_name)
  values (v_card, 900, 'PASSIVE', 'SELF', 'MODIFY_STAT', 42, 'EVASION_PCT');
  perform t_ok(true, 'EVASION_PCT is accepted as a stat_name');

  -- The compiler actually derives cards.evasion_pct from it -- not merely
  -- saveable, real end to end.
  perform cn_compile_card_effects(v_card);
  perform t_ok((select evasion_pct from public.cards where id = v_card) = 42,
              'cn_compile_card_effects sets cards.evasion_pct from the PASSIVE row');

  delete from public.card_effects where card_id = v_card and sort = 900;
  perform cn_compile_card_effects(v_card);
  perform t_ok((select evasion_pct from public.cards where id = v_card) = 0,
              'and deleting the row resets it to 0, same as every other compiled stat');

  -- Backward compat: 0059 does NOT remove SLIPPERY/FLIES from the schema,
  -- only from AdminCards.tsx's offered list -- Himanta's existing SLIPPERY
  -- row (and anything already carrying FLIES) must keep saving fine.
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name)
  values (v_card, 900, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'SLIPPERY');
  perform t_ok(true, 'SLIPPERY still saves fine -- not removed from the schema');
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, stat_name)
  values (v_card, 901, 'PASSIVE', 'SELF', 'MODIFY_STAT', 'FLIES');
  perform t_ok(true, 'FLIES still saves fine -- not removed from the schema either');

  delete from public.card_effects where card_id = v_card and sort >= 900;
  perform cn_compile_card_effects(v_card);
end $$;

-- ---- cards.evasion_pct's own check constraint ----------------------------
do $$
begin
  perform t_raises(
    'update public.cards set evasion_pct = 150 where slug = ''ashvar''',
    'cards_evasion_pct_check',
    'evasion_pct over 100 is refused');
  perform t_raises(
    'update public.cards set evasion_pct = -1 where slug = ''ashvar''',
    'cards_evasion_pct_check',
    'evasion_pct below 0 is refused');
  update public.cards set evasion_pct = 0 where slug = 'ashvar';
end $$;

-- ---- runtime: a guaranteed evasion means no damage, no counter, no chain --
create or replace function t_sw(p_m uuid) returns jsonb language sql stable as $$
  select coalesce(state->'fx'->'swings', '[]'::jsonb) from public.matches where id = p_m;
$$;
create or replace function t_shape(p_m uuid) returns text language sql stable as $$
  select coalesce(string_agg((s->>'k') || ':' || (s->>'by'), ',' order by i), '')
    from jsonb_array_elements(t_sw(p_m)) with ordinality t(s, i);
$$;

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ee000000-0000-0000-0000-0000000000e1','e1@x.com','{"username":"eone"}'),
  ('ee000000-0000-0000-0000-0000000000e2','e2@x.com','{"username":"etwo"}');

select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select public.set_deck(array['dereo','dorme','lium','sinie','fey']);
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e2',false);
select public.set_deck(array['dereo','ashvar','velmor','nyxara','sarrave']);
select t_match('ee000000-0000-0000-0000-0000000000e1',
               'ee000000-0000-0000-0000-0000000000e2') as m \gset
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);

-- g1 (King Dereo) defends with a CERTAIN evasion -- 100 is not a roll, per
-- cn_chance's own >=100 short-circuit, so this is deterministic without
-- touching cn.force_evasion at all (proving that shortcut extends to the
-- new 'evasion' kind for free, same as it already does for parry/crit).
select t_place(:'m','h1',2,2); select t_place(:'m','g1',2,3);
select t_set(:'m','g1','evasionPct','100'::jsonb);
select t_set(:'m','g1','parryPct','0'::jsonb); select t_set(:'m','h1','parryPct','0'::jsonb);
select t_hp(:'m','g1',60); select t_set(:'m','g1','maxHp','100'::jsonb);
select t_hp(:'m','h1',100); select t_set(:'m','h1','maxHp','100'::jsonb);
select public.submit_attack(:'m','h1','g1');
select t_ok(t_shape(:'m') = 'hit:h1',
            'a certain evasion is ONE swing, not a chain -- no counter answers it');
select t_ok((t_sw(:'m')->0->>'dmg')::int = 0 and t_sw(:'m')->0->>'why' = 'evade',
            'that one swing is recorded as a dmg-0 evade, not a normal miss');
select t_ok(t_get(:'m','g1','hp')::int = 60,
            'g1 took no damage at all -- the blow never connected');
select t_ok(t_get(:'m','h1','hp')::int = 100,
            'and h1 took no counter either -- nothing to counter with');

-- Same exchange, evasion back at its default (0) -- proves the roll is not
-- unconditionally short-circuiting true, only when the stat says so.
select t_reset(:'m');
select t_set(:'m','g1','evasionPct','0'::jsonb);
select t_set(:'m','g1','crmin','1'::jsonb); select t_set(:'m','g1','crmax','1'::jsonb);
select t_hp(:'m','g1',60); select t_hp(:'m','h1',100);
select public.submit_attack(:'m','h1','g1');
select t_ok(t_get(:'m','g1','hp')::int < 60,
            'evasionPct=0 (the default every existing card has): ordinary combat, real damage lands');

-- ---- condition fields: self.hp / target.hp (flat) vs self.hp_pct/target.hp_pct ----
do $$
declare v_ctx jsonb;
begin
  v_ctx := jsonb_build_object('self', jsonb_build_object('hp', 20, 'maxHp', 100),
                              'target', jsonb_build_object('hp', 75, 'maxHp', 100));

  perform t_ok(cn_effect_condition_met('{"field":"self.hp","op":"<","value":"25"}'::jsonb, v_ctx),
              'self.hp < 25 is true at flat hp=20 (not a percentage read)');
  perform t_ok(not cn_effect_condition_met('{"field":"self.hp","op":"<","value":"15"}'::jsonb, v_ctx),
              'self.hp < 15 is false at flat hp=20');
  perform t_ok(cn_effect_condition_met('{"field":"self.hp_pct","op":"<","value":"25"}'::jsonb, v_ctx),
              'self.hp_pct < 25 still reads as a percentage (20/100 = 20%) -- unchanged by this migration');
  perform t_ok(cn_effect_condition_met('{"field":"target.hp","op":">=","value":"75"}'::jsonb, v_ctx),
              'target.hp >= 75 is true at flat hp=75');
  perform t_ok(not cn_effect_condition_met('{"field":"target.hp","op":">","value":"75"}'::jsonb, v_ctx),
              'target.hp > 75 is false -- boundary is exact, not off-by-one');
end $$;
