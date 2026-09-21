-- 0077: burn also costs you for USING AN ABILITY, not only for swinging.
--
-- Jared: "make it so that burn hurts anytime you attack, use an ability
-- (not a passive), counter-attack, or deal damage with parry." Three of the
-- four already worked, all through cn_attack's own chain loop (see 0077's
-- migration header for why attack/counter/parry are really one loop).
-- cn_ability never went near that loop, so it never charged the cost --
-- this file is only about closing that one gap.
--
-- Mako is the test subject on purpose: her ability is a scripted
-- CREATE_STRUCTURE (a bomb) that touches nothing about her own hp, target or
-- value -- so any hp SHE loses after using it can only be the new burn
-- charge, nothing the ability itself did.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ff000000-0000-0000-0000-0000000000d1','d1@x.com','{"username":"done"}'),
  ('ff000000-0000-0000-0000-0000000000d2','d2@x.com','{"username":"dtwo"}');

select set_config('app.uid','ff000000-0000-0000-0000-0000000000d1',false);
select public.set_deck(array['dereo','eva','mako','fey','lumea']);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000d2',false);
select public.set_deck(array['dereo','dione-grifo','sinie','himanta','wuzu']);
select t_match('ff000000-0000-0000-0000-0000000000d1',
               'ff000000-0000-0000-0000-0000000000d2') as m \gset
select set_config('app.uid','ff000000-0000-0000-0000-0000000000d1',false);
select t_trees(:'m','[]'::jsonb);
-- Stripped the same way 25_effects.sql strips them for its own burn-number
-- assertions: King Stelaris (or anyone else's Royal) halving a burn is that
-- file's story, not this one's. This one is about whether the charge is
-- levied at all for an ability, at the plain, unmodified rate.
select t_noauras(:'m');
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h3','name') = 'Mako',
            'h3 is Mako in this deck order -- same slot she takes in 24_abilities with the same array');
select t_place(:'m','h3',2,2);

-- ---- regression: a unit who is NOT on fire pays nothing extra -------------
select t_reset(:'m'); select t_full(:'m','h3'); select t_clear(:'m','h3');
select public.submit_ability(:'m','h3','@2,3');
select t_ok(t_nobj(:'m','bomb') = 1, 'the ability itself still works exactly as before -- one bomb, placed');
select t_ok(t_get(:'m','h3','hp')::int = t_get(:'m','h3','maxHp')::int,
            'NOT ON FIRE: using the ability costs nothing extra -- 0077 only ever adds a cost for a burning caster');
select t_ok(t_fx(:'m','burnAtk')::int = 0, 'and fx says so plainly: no burn at all');
select t_ok(t_fx(:'m','killedAtk') = 'false', 'nobody died from a charge that never happened');
select t_ok((select state->'log'->-1->>'text' from public.matches where id=:'m') not like '%burns for%',
            'and the log carries no burn line for a caster who was never burning');

-- ---- a burning unit pays 15% of maxHp, same rate cn_attack has always
-- charged a swinging attacker (see 25_effects.sql, which pins the same
-- number for Mako specifically: 60 maxHp, 15% is 9) --------------------------
select t_reset(:'m');
-- "one live structure per unit at a time" (0064) would otherwise no-op the
-- next placement below, since the bomb from the block above is still
-- standing -- clearing it is set dressing for THIS test, not part of what
-- it is proving.
select t_trees(:'m','[]'::jsonb);
select t_full(:'m','h3'); select t_burn(:'m','h3');
select public.submit_ability(:'m','h3','@2,3');
select t_ok(t_nobj(:'m','bomb') = 1, 'still places the bomb -- burn is a cost levied ON TOP of the ability, not instead of it');
select t_ok(t_get(:'m','h3','hp')::int = 51,
            'ON FIRE: 60 maxHp at cn_burn_pct() 15% is 9 -- Mako pays it for USING the ability, not just for swinging');
select t_ok(t_fx(:'m','burnAtk')::int = 9, 'fx.burnAtk carries the real number');
select t_ok(t_fx(:'m','killedAtk') = 'false', 'and this charge did not finish her');
select t_ok((select count(*) from public.matches mm, jsonb_array_elements(mm.state->'fx'->'hits') e
              where mm.id = :'m' and e->>'id' = 'h3' and (e->>'dmg')::int = 9) = 1,
            'AND IT SHOWS UP IN fx.hits -- the client''s fx.kind===''ability'' path only ever reads hits, never burnAtk directly, so this is what actually makes the pop-number appear on screen');
select t_ok((select count(*) from public.matches mm, jsonb_array_elements(mm.state->'fx'->'swings') e
              where mm.id = :'m' and e->>'k' = 'burn' and e->>'by' = 'h3' and e->>'at' = 'h3') = 1,
            'and as its own ''burn'' swing entry, the same vocabulary cn_attack''s chain loop already uses');
select t_ok((select state->'log'->-1->>'text' from public.matches where id=:'m') like '%burns for 9%',
            'and the log reads exactly like an attack-caused burn would');

-- ---- and it can finish her, exactly like a burn already can on a swing ----
select t_reset(:'m'); select t_trees(:'m','[]'::jsonb);
-- Still burning from the block above (t_reset only clears moved/acted/spent/
-- acts/active, never effects -- see _helpers.sql). Dropped low enough that
-- 9 damage (15%% of her 60 maxHp) is lethal.
select t_hp(:'m','h3',5);
select public.submit_ability(:'m','h3','@2,3');
select t_ok(t_nobj(:'m','bomb') = 1,
            'the bomb still lands -- CREATE_STRUCTURE runs before the burn charge is even computed, same order cn_attack keeps for its own tree branch');
select t_ok(not t_alive(:'m','h3'), 'A LETHAL BURN REMOVES HER FROM THE BOARD, same as a burn-killed attacker in cn_attack');
select t_ok((select exists (select 1 from jsonb_array_elements(
               coalesce((select state->'graveyard'->'host' from public.matches where id=:'m'), '[]'::jsonb)) g
              where g->>'id' = 'h3')),
            'and she is archived in the graveyard (cn_bury) rather than just vanishing');
select t_ok(t_fx(:'m','killedAtk') = 'true', 'fx says the charge was what killed her');
select t_ok((select state->'log'->-1->>'text' from public.matches where id=:'m') like '%burns for%-- destroyed.%',
            'and the log spells out that the burn is what finished her');

-- ---- a passive is not this gate -- cn_ability is never how a passive fires ---
-- h1 (Dereo, a Royal) has no abilityKind at all in this deck -- same as h1
-- in 24_abilities.sql ("a Royal has no ability to use"). Burning changes
-- nothing about that: cn_ability refuses her outright before it ever gets
-- anywhere near the new burn charge, so a passive (or, here, simply having
-- none) can never reach it through this RPC -- exactly the "not a passive"
-- half of the request, satisfied by cn_ability's existing shape rather than
-- by anything new 0077 had to add.
select t_ok(t_get(:'m','h1','abilityKind') is null, 'h1 has no ability to use in this deck, same slot as 24_abilities');
select t_reset(:'m');
select t_burn(:'m','h1');
select t_raises(format('select public.submit_ability(%L,''h1'',null)', :'m'),
                'no ability', 'a unit with no ability still cannot "use" one, burning or not');
