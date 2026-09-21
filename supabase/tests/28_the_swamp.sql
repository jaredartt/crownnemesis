-- 0037: Umiro, and the end of Phase F.
--
-- "Nearby units cannot use Passives or Abilities." The whole migration is one
-- function, cn_awake(), and six places it is called -- so this file asks the
-- same question once per place, and asks it twice each time: does the rule
-- stop next to Umiro, and does it start again a tile further away? The second
-- half of each pair is the one that matters. A swamp that silenced the whole
-- board would pass every "it is silenced" assertion ever written.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ddee0000-0000-0000-0000-0000000000de','w1@x.com','{"username":"one"}'),
  ('ff110000-0000-0000-0000-0000000000f1','w2@x.com','{"username":"two"}');

-- ---- the card --------------------------------------------------------------
select t_ok((select swamps from public.cards where slug = 'umiro'),
            'UMIRO BRINGS THE SWAMP');
select t_ok((select count(*) from public.cards where swamps) = 1,
            'and nobody else does');
select t_ok((select ability_kind from public.cards where slug = 'umiro') is null,
            'and it is a passive — there is nothing to activate');

-- ---- cn_awake, on a board built by hand ------------------------------------
-- By hand rather than from a match, because the claim here is about the
-- function and a match would only be five cards standing in the way of it.
\set B '{"units":[{"id":"u","x":1,"y":1,"hp":75,"owner":"host","swamps":true},{"id":"n","x":2,"y":1,"hp":70,"owner":"guest","stuns":true,"twicePct":25,"parries":true,"parryAll":true,"slippery":true,"regenPct":5,"poisonsAdj":true,"vsPoisoned":25,"lifestealPct":100,"abilityKind":"summon","summonKind":"bomb","auraKind":"resist_effects","flies":true,"tramples":true,"parryPct":10,"critPct":10,"swamps":false},{"id":"f","x":5,"y":5,"hp":70,"owner":"guest","stuns":true,"twicePct":25,"abilityKind":"summon","flies":true,"swamps":false}]}'
select t_ok(cn_swamped(:'B'::jsonb, :'B'::jsonb->'units'->1),
            'A UNIT STANDING NEXT TO UMIRO IS IN THE SWAMP');
select t_ok(not cn_swamped(:'B'::jsonb, :'B'::jsonb->'units'->2),
            'AND ONE STANDING AWAY FROM HIM IS NOT');
-- TWO UMIROS. The one case where "is this unit itself" looks like it matters,
-- and it does not: a unit is never one tile from itself, so nobody is ever
-- their own swamp -- but two of them side by side silence EACH OTHER, and
-- the flag that makes them a swamp is the one flag cn_awake never strips, so
-- neither of them stops being one. Without this pair, forcing `swamps` to
-- false inside cn_awake changes nothing any assertion can see.
\set BB '{"units":[{"id":"u1","x":1,"y":1,"hp":75,"owner":"host","swamps":true,"stuns":true},{"id":"u2","x":2,"y":1,"hp":75,"owner":"guest","swamps":true,"stuns":true}]}'
select t_ok(cn_swamped(:'BB'::jsonb, :'BB'::jsonb->'units'->0)
        and cn_swamped(:'BB'::jsonb, :'BB'::jsonb->'units'->1),
            'TWO UMIROS SILENCE EACH OTHER');
select t_ok((cn_awake(:'BB'::jsonb, :'BB'::jsonb->'units'->0)->>'swamps')::boolean
        and (cn_awake(:'BB'::jsonb, :'BB'::jsonb->'units'->1)->>'swamps')::boolean,
            'AND NEITHER STOPS BEING ONE — the swamp is never silenced');
select t_ok((cn_awake(:'BB'::jsonb, :'BB'::jsonb->'units'->0)->>'stuns')::boolean = false,
            'though everything else about them goes, the same as anybody');
select t_ok(not cn_swamped('{"units":[{"id":"u","x":1,"y":1,"hp":75,"swamps":true}]}'::jsonb,
                           '{"id":"u","x":1,"y":1,"hp":75,"swamps":true}'::jsonb),
            'and one standing alone is not in its own');

-- Everything the swamp takes, named one at a time. A loop over a list would
-- read better and tell you nothing about WHICH one stopped being stripped.
select t_ok(cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'abilityKind' is null
        and cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'summonKind' is null
        and cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'auraKind' is null,
            'THE SWAMP TAKES THE ABILITY, what it summons, and the aura');
select t_ok((cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'parries')::boolean = false
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'parryAll')::boolean = false
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'slippery')::boolean = false
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'stuns')::boolean = false
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'poisonsAdj')::boolean = false,
            'and every passive FLAG');
select t_ok((cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'twicePct')::int = 0
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'regenPct')::int = 0
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'vsPoisoned')::int = 0
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'lifestealPct')::int = 0,
            'and every passive NUMBER');

-- And everything it deliberately leaves. These are the judgement calls, and
-- they are written down here so a later reader finds the decision rather than
-- the symptom.
select t_ok((cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'flies')::boolean
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'tramples')::boolean,
            'IT DOES NOT TAKE FLIGHT — that is a class, not a passive');
select t_ok((cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'hp')::int = 70
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'parryPct')::int = 10
        and (cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->1)->>'critPct')::int = 10,
            'nor the body, nor the dice — Lium keeps his rates and loses his catch');
select t_ok(cn_awake(:'B'::jsonb, :'B'::jsonb->'units'->2)
              = :'B'::jsonb->'units'->2,
            'a unit out of the marsh comes back untouched, byte for byte');

-- ---- a live board ----------------------------------------------------------
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);
select public.set_deck(array['stelaris','umiro','sinie','wuzu','sarrave']);
select set_config('app.uid','ff110000-0000-0000-0000-0000000000f1',false);
select public.set_deck(array['dereo','dorme','himanta','zephyra','nyxara']);
select t_match('ddee0000-0000-0000-0000-0000000000de',
               'ff110000-0000-0000-0000-0000000000f1') as m \gset
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h2','name') = 'Umiro' and (t_get(:'m','h2','swamps'))::boolean,
            'the board has Umiro on the host side, and the snapshot carries it');

-- ---- the ability -----------------------------------------------------------
-- Said out loud rather than left to fall through into 'that unit has no
-- ability': "not this card" and "not while you are standing there" are
-- different news.
select t_reset(:'m');
select t_place(:'m','h3',2,2); select t_place(:'m','h2',2,3);
select t_raises(format($$select public.submit_ability(%L,'h3','h4')$$, :'m'),
                'in the swamp', 'AN ABILITY IS REFUSED NEXT TO UMIRO, and says why');
select t_place(:'m','h2',5,5);
select t_place(:'m','h4',2,3); select t_dmg(:'m','h4',10); select t_hp(:'m','h4',40);
select public.submit_ability(:'m','h3','h4');
select t_ok(t_get(:'m','h4','hp')::int = 70,
            'AND ALLOWED A TILE FURTHER AWAY — Sinie mends for thirty');

-- ---- the exchange ----------------------------------------------------------
-- Quick Dagger, which is the easiest of the nine to see: it answers BEFORE the
-- blow it is answering, so its absence changes the SHAPE of the exchange and
-- not merely a number.
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g3','g4','g5']);
select t_place(:'m','h3',2,2); select t_place(:'m','g2',2,3);
select t_full(:'m','h3'); select t_full(:'m','g2');
select t_ok((t_get(:'m','g2','parries'))::boolean, 'Dorme carries Quick Dagger');
select t_place(:'m','h2',5,5);
select public.submit_attack(:'m','h3','g2');
select t_ok(t_swi(:'m',0,'why') = 'quick',
            'and it lands FIRST when nobody is standing in the marsh');

select t_reset(:'m'); select t_full(:'m','h3'); select t_full(:'m','g2');
select t_place(:'m','h2',3,3);
select t_ok(cn_swamped((select state from public.matches where id = :'m'),
                       (select u from public.matches m, jsonb_array_elements(m.state->'units') u
                         where m.id = :'m' and u->>'id' = 'g2')),
            'Umiro steps in beside Dorme');
select public.submit_attack(:'m','h3','g2');
select t_ok(t_swi(:'m',0,'why') <> 'quick',
            'AND THE DAGGER IS GONE — the blow lands before the answer again');
select t_place(:'m','h2',5,5);

-- Zephyra's cyclone, from the other end: the SWAMPED unit is the one swinging.
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g5']);
select t_place(:'m','g4',2,2); select t_place(:'m','h3',2,3);
select t_full(:'m','g4'); select t_full(:'m','h3'); select t_clear(:'m','h3');
select t_ok((t_get(:'m','g4','stuns'))::boolean, 'Zephyra carries the cyclone');
-- The turn has to change hands for a guest unit to swing, and only the side
-- whose turn it IS may end it -- so the host ends it and the guest picks it up.
select public.end_turn(:'m');
select set_config('app.uid','ff110000-0000-0000-0000-0000000000f1',false);
select public.submit_attack(:'m','g4','h3');
select t_ok((t_get(:'m','h3','effects')::jsonb->>'stun')::int = 1,
            'and it stuns what it hits');
select t_reset(:'m'); select t_full(:'m','h3'); select t_clear(:'m','h3');
-- Umiro beside Zephyra, placed by the rigging rather than walked there: it is
-- still the guest's turn and the point is the swing, not the walk. (2,1),
-- not (1,1) -- 0076 made a diagonal neighbour cost 2, not 1, so "beside" for
-- cn_swamped's own distance-1 check now means straight up, not the corner.
select t_place(:'m','h2',2,1);
select public.submit_attack(:'m','g4','h3');
select t_ok((t_get(:'m','h3','effects')::jsonb->>'stun')::int = 0,
            'A SWAMPED ZEPHYRA STUNS NOBODY');
select t_place(:'m','h2',5,5);
select public.end_turn(:'m');
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);

-- ---- the aura --------------------------------------------------------------
-- King Stelaris halves a burn for his whole team. Standing him next to the
-- other side's Umiro turns that off, which is the most useful thing the swamp
-- can do and the reason cn_aura is gated rather than cn_aura_bonus.
select t_reset(:'m'); select t_park(:'m', array['h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'m','h1',0,0);
select t_place(:'m','h3',2,2); select t_place(:'m','g2',2,3);
select t_hp(:'m','h3',60); select t_dmg(:'m','h3',10); select t_burn(:'m','h3');
select public.submit_attack(:'m','h3','g2');
-- Sinie's maximum is 65, so the fire costs round(65 * 15%) = 10, and the
-- crown takes half of that. Ten and five, not nine and five: the percentage
-- is of the MAXIMUM and t_hp only moves what is left.
select t_ok(t_fx(:'m','burnAtk')::int = 5,
            'STELARIS HALVES A BURN — ten becomes five on his side');
select t_reset(:'m'); select t_hp(:'m','h3',60); select t_burn(:'m','h3');
select t_place(:'m','h2',1,0);
select public.submit_attack(:'m','h3','g2');
select t_ok(t_fx(:'m','burnAtk')::int = 10,
            'AND A CROWN IN THE MARSH GRANTS NOTHING — the full ten again');
select t_place(:'m','h2',5,5); select t_clear(:'m','h3');

-- ---- the turn --------------------------------------------------------------
-- Wuzu mends five per cent of a maximum at the start of its own side's turn.
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h5','g1','g2','g3','g4','g5']);
-- t_clear, and not only t_hp: t_reset restores FLAGS, not afflictions, and
-- Wuzu picked up a poison two blocks ago. Without this the regeneration
-- happened exactly as it should and the tick took more than it gave, which
-- reads from the outside as "the mend did not fire".
select t_place(:'m','h4',2,2); select t_hp(:'m','h4',40); select t_clear(:'m','h4');
select public.end_turn(:'m');
select set_config('app.uid','ff110000-0000-0000-0000-0000000000f1',false);
select public.end_turn(:'m');
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);
select t_ok(t_get(:'m','h4','hp')::int = 44,
            'WUZU MENDS AT THE START OF ITS TURN — 5% of eighty-five');

select t_hp(:'m','h4',40); select t_clear(:'m','h4');
select t_place(:'m','h2',2,3);
select public.end_turn(:'m');
select set_config('app.uid','ff110000-0000-0000-0000-0000000000f1',false);
select public.end_turn(:'m');
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);
select t_ok(t_get(:'m','h4','hp')::int = 40,
            'AND NOT IN THE SWAMP — its own side''s Umiro, at that');
select t_place(:'m','h2',5,5);

-- Sarrave poisons every adjacent tile at the start of its own turn.
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','g1','g2','g3','g4','g5']);
select t_place(:'m','h5',2,2); select t_place(:'m','g2',2,3); select t_clear(:'m','g2');
select public.end_turn(:'m');
select set_config('app.uid','ff110000-0000-0000-0000-0000000000f1',false);
select public.end_turn(:'m');
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);
select t_ok((t_get(:'m','g2','effects')::jsonb->>'poison')::boolean,
            'SARRAVE POISONS EVERY TILE AROUND IT');
select t_clear(:'m','g2'); select t_place(:'m','h2',2,1);
select public.end_turn(:'m');
select set_config('app.uid','ff110000-0000-0000-0000-0000000000f1',false);
select public.end_turn(:'m');
select set_config('app.uid','ddee0000-0000-0000-0000-0000000000de',false);
select t_ok(not (t_get(:'m','g2','effects')::jsonb->>'poison')::boolean,
            'AND NOTHING AT ALL FROM THE MARSH');
