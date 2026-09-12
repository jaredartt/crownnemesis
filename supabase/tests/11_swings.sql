-- 0020: the exchange, blow by blow.
--
-- Two things are being tested and the second matters more than the first.
--
-- One: the list says what happened, in the order it happened -- which parry
-- caught which swing, which blow was a crit, who fell and when.
--
-- Two, and this is the one that can rot: the list AGREES with the sums that
-- were already there. `dmg`, `counter`, `riposte`, `parries` and `chain` are
-- what the log and the board have always been drawn from, and the cinematic
-- will be drawn from the list. If the two ever drift, the picture and the
-- words under it stop describing the same fight -- so every section below that
-- swings anything asserts the reconciliation as well.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('eeee0000-0000-0000-0000-00000000000e','e@x.com','{"username":"eli"}'),
  ('ffff0000-0000-0000-0000-00000000000f','f@x.com','{"username":"fern"}');

-- ---- reading the list ------------------------------------------------------
create or replace function t_sw(p_m uuid) returns jsonb language sql stable as $$
  select coalesce(state->'fx'->'swings', '[]'::jsonb) from public.matches where id = p_m;
$$;
-- The shape of an exchange as one string, so a whole sequence is one assertion
-- rather than six. 'hit:h1,parry:h1,hit:g3' reads as a fight.
create or replace function t_shape(p_m uuid) returns text language sql stable as $$
  select coalesce(string_agg((s->>'k') || ':' || (s->>'by'), ',' order by i), '')
    from jsonb_array_elements(t_sw(p_m)) with ordinality t(s, i);
$$;
create or replace function t_swi(p_m uuid, p_i int, p_key text) returns text
language sql stable as $$ select t_sw(p_m)->(p_i)->>p_key $$;
-- Everything one unit took off, across every swing of the exchange.
create or replace function t_dealt(p_m uuid, p_by text) returns int
language sql stable as $$
  select coalesce(sum((s->>'dmg')::int), 0)::int
    from jsonb_array_elements(t_sw(p_m)) s
   where s->>'k' = 'hit' and s->>'by' = p_by;
$$;

select t_match('eeee0000-0000-0000-0000-00000000000e',
               'ffff0000-0000-0000-0000-00000000000f') as m \gset

-- Two units a tile apart, both fixed to 40, everything else ordinary. Copied
-- from 09_combat.sql's t_duel rather than shared with it: this file has to
-- keep passing on the day somebody retunes that one.
create or replace function t_duel2(p_m uuid) returns void language sql as $$
  select t_reset(p_m), t_noauras(p_m),
         t_place(p_m,'h1',2,2), t_place(p_m,'g3',2,3),
         t_full(p_m,'h1'), t_full(p_m,'g3'),
         t_dmg(p_m,'h1',40), t_dmg(p_m,'g3',40),
         t_set(p_m,'h1','rmin','1'::jsonb), t_set(p_m,'h1','rmax','1'::jsonb),
         t_set(p_m,'h1','crmin','1'::jsonb), t_set(p_m,'h1','crmax','1'::jsonb),
         t_set(p_m,'g3','rmin','1'::jsonb), t_set(p_m,'g3','rmax','1'::jsonb),
         t_set(p_m,'g3','crmin','1'::jsonb), t_set(p_m,'g3','crmax','1'::jsonb),
         t_hp(p_m,'h1',110), t_hp(p_m,'g3',110), t_set(p_m,'g3','maxHp','110'::jsonb),
         t_set(p_m,'h1','parryPct','5'::jsonb), t_set(p_m,'g3','parryPct','5'::jsonb),
         t_set(p_m,'h1','critPct','5'::jsonb),  t_set(p_m,'g3','critPct','5'::jsonb),
         t_set(p_m,'h1','parries','false'::jsonb), t_set(p_m,'g3','parries','false'::jsonb),
         t_set(p_m,'h1','parryAll','false'::jsonb), t_set(p_m,'g3','parryAll','false'::jsonb),
         t_set(p_m,'h1','heals','false'::jsonb),  t_set(p_m,'g3','heals','false'::jsonb),
         t_set(p_m,'h1','burned','false'::jsonb), t_set(p_m,'g3','burned','false'::jsonb),
         t_set(p_m,'h1','defending','false'::jsonb), t_set(p_m,'g3','defending','false'::jsonb);
$$;

set cn.force_parry = 'never'; set cn.force_crit = 'never';

-- ---- the ordinary trade ----------------------------------------------------
select t_duel2(:'m');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_shape(:'m') = 'hit:h1,hit:g3',
            'a plain trade is two swings: the blow, then the answer');
select t_ok(t_swi(:'m',0,'dmg')::int = 40 and t_swi(:'m',0,'counter') = 'false'
            and t_swi(:'m',0,'why') = 'strike',
            'the first is the strike, at full');
select t_ok(t_swi(:'m',1,'dmg')::int = 20 and t_swi(:'m',1,'counter') = 'true'
            and t_swi(:'m',1,'why') = 'counter',
            'the second is the answer, at half');
select t_ok(t_swi(:'m',0,'crit') = 'false' and t_swi(:'m',0,'def') = 'false'
            and t_swi(:'m',0,'first') = 'false',
            'and nothing else is claimed about it');
-- the reconciliation
select t_ok(t_dealt(:'m','h1') = t_fx(:'m','dmg')::int + t_fx(:'m','riposte')::int,
            'what the attacker dealt adds up to dmg plus riposte');
select t_ok(t_dealt(:'m','g3') = t_fx(:'m','counter')::int,
            'and what came back adds up to counter');
select t_ok((select count(*) from jsonb_array_elements(t_sw(:'m')) s
              where s->>'k' in ('hit','parry')) = t_fx(:'m','chain')::int,
            'and the swings that were swung are the chain');

-- ---- a crit is marked on the swing that was one ----------------------------
set cn.force_crit = 'always';
select t_duel2(:'m');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_swi(:'m',0,'crit') = 'true' and t_swi(:'m',1,'crit') = 'true',
            'both swings of a forced-crit trade are flagged');
select t_ok(t_swi(:'m',0,'dmg')::int = 60 and t_swi(:'m',1,'dmg')::int = 30,
            'and carry the numbers the crit produced');
select t_ok(t_dealt(:'m','h1') = t_fx(:'m','dmg')::int + t_fx(:'m','riposte')::int
            and t_dealt(:'m','g3') = t_fx(:'m','counter')::int,
            'a critical exchange still reconciles');
set cn.force_crit = 'never';

-- ---- a guard is recorded on the swing it softened --------------------------
select t_duel2(:'m');
select t_set(:'m','g3','defending','true'::jsonb);
select public.submit_attack(:'m','h1','g3');
select t_ok(t_swi(:'m',0,'def') = 'true', 'the blow knows it hit a raised guard');
select t_ok(t_swi(:'m',0,'dmg')::int = 20, 'and was halved by it');
select t_ok(t_swi(:'m',1,'def') = 'false',
            'while the answer, which hit nobody''s guard, is not marked');

-- ---- a parry, and who caught it --------------------------------------------
set cn.force_parry = 'always';
select t_duel2(:'m');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_swi(:'m',0,'k') = 'parry' and t_swi(:'m',0,'by') = 'g3',
            'the defender catches the opening blow');
select t_ok(t_swi(:'m',0,'why') = 'roll', 'by the roll, which is what it was');
select t_ok((select count(*) from jsonb_array_elements(t_sw(:'m')) s
              where s->>'k' = 'parry') = t_fx(:'m','parries')::int,
            'the parries in the list are the parries in the count');
select t_ok((select count(*) from jsonb_array_elements(t_sw(:'m')) s
              where s->>'k' in ('hit','parry')) = t_fx(:'m','chain')::int,
            'and the chain still counts the same swings');
select t_ok(t_dealt(:'m','h1') = 0 and t_dealt(:'m','g3') = 0,
            'a fight that was all parries took nothing off anybody');
select t_ok((select count(*) from jsonb_array_elements(t_sw(:'m')) s
              where s->>'k' = 'parry') = public.cn_parry_cap(),
            'eight parries and not a ninth');

-- Lium catches an ANSWER because he is Lium, not because a die said so, and
-- the list has to be able to tell the caption which of the two it was.
set cn.force_parry = 'never';
select t_duel2(:'m');
select t_set(:'m','h1','parryAll','true'::jsonb);
select t_set(:'m','h1','parryPct','0'::jsonb);
select t_set(:'m','g3','parryPct','0'::jsonb);
select public.submit_attack(:'m','h1','g3');
select t_ok(t_shape(:'m') = 'hit:h1,parry:h1,hit:h1',
            'the blow lands, the answer is caught, and the catch is answered');
select t_ok(t_swi(:'m',1,'why') = 'all',
            'the catch is marked as the passive, not a roll');
-- Three swings and not two, which is the rule and not an accident: a parry
-- answers if the parrier can reach what it caught, and Lium standing next to
-- the thing he just caught can. So catching an answer earns him a free blow.
select t_ok(t_swi(:'m',2,'by') = 'h1' and t_swi(:'m',2,'counter') = 'true',
            'and it is Lium answering his own parry');
select t_ok(t_dealt(:'m','h1') = t_fx(:'m','dmg')::int + t_fx(:'m','riposte')::int,
            'his free blow lands in riposte, and it reconciles');

-- ---- Quick Dagger answers before the blow it answers ------------------------
select t_duel2(:'m');
select t_set(:'m','g3','parries','true'::jsonb);
select public.submit_attack(:'m','h1','g3');
select t_ok(t_swi(:'m',0,'k') = 'hit' and t_swi(:'m',0,'by') = 'g3'
            and t_swi(:'m',0,'first') = 'true' and t_swi(:'m',0,'why') = 'quick',
            'the dagger''s answer is the first swing in the list');
select t_ok((select count(*) from jsonb_array_elements(t_sw(:'m')) s
              where s->>'first' = 'true') = 1,
            'and it is the only swing that ever claims to come first');
select t_ok(t_dealt(:'m','g3') = t_fx(:'m','counter')::int,
            'a dagger exchange reconciles too');

-- ---- going down is a beat, and it is in the right place ---------------------
-- g4 takes this one, not g3. A killed unit leaves the board for good, and
-- every section below still needs g3 standing -- which is the same reason
-- 09_combat.sql kills somebody else too.
select t_duel2(:'m'); select t_place(:'m','g3',5,5);
select t_place(:'m','g4',2,3); select t_hp(:'m','g4',30); select t_dmg(:'m','g4',40);
select t_set(:'m','g4','crmin','1'::jsonb); select t_set(:'m','g4','crmax','1'::jsonb);
select public.submit_attack(:'m','h1','g4');
select t_ok(t_shape(:'m') = 'hit:h1,down:g4',
            'the blow, then the falling -- and nothing after it');
select t_ok(t_fx(:'m','killedTgt') = 'true', 'which is what the old flag says too');
select t_ok(not t_alive(:'m','g4'), 'and the board agrees it has gone');

-- ---- burning costs you on the swing -----------------------------------------
-- `burned` became `effects.burn` in 0034, and the fire costs 15% of a maximum
-- rather than a flat 5. The SHAPE is what this file is about and it is
-- unchanged, which is the point of asserting it here.
select t_duel2(:'m');
select t_burn(:'m','h1');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_shape(:'m') = 'hit:h1,burn:h1,hit:g3',
            'the fire eats between the blow and the answer');
-- 15% of the 110 t_duel2 rigs = 17, since 0034.
select t_ok(t_swi(:'m',1,'dmg')::int = 17 and t_fx(:'m','burnAtk')::int = 17,
            'for 15% of a maximum, and the old field agrees');

-- ---- mending is one beat and draws nothing back -----------------------------
select t_duel2(:'m');
select t_set(:'m','h1','heals','true'::jsonb);
select t_place(:'m','h2',2,1); select t_hp(:'m','h2',20);
select public.submit_attack(:'m','h1','h2');
select t_ok(t_shape(:'m') = 'heal:h1', 'a mend is a single beat');
select t_ok(t_swi(:'m',0,'dmg')::int = t_fx(:'m','heal')::int,
            'and carries the same number the old field does');

-- ---- a tree is struck, and falls --------------------------------------------
-- t_duel2 restores flags and health; it does NOT lift an affliction, and the
-- fire two blocks up is still on h1. Since 0034 a burning unit pays on a
-- swing at a TREE as well, which would put an extra beat in this shape.
select t_duel2(:'m'); select t_clear(:'m','h1');
select t_trees(:'m', '[{"id":"t1","x":2,"y":1,"hp":30,"maxHp":30}]'::jsonb);
select public.submit_attack(:'m','h1','t1');
select t_ok(t_shape(:'m') = 'hit:h1,down:t1', 'a felled tree gets its own falling');
select t_ok(t_swi(:'m',0,'why') = 'tree', 'and the blow says what it hit');
select t_ok(t_swi(:'m',0,'dmg')::int = t_fx(:'m','dmg')::int,
            'with the number the old field carries');

-- A tree does not answer, but the fire does not care what you swung at. Before
-- 0034 this branch read the retired `burned` field and so charged nobody.
select t_duel2(:'m'); select t_burn(:'m','h1');
select t_trees(:'m', '[{"id":"t1","x":2,"y":1,"hp":30,"maxHp":30}]'::jsonb);
select public.submit_attack(:'m','h1','t1');
select t_ok(t_shape(:'m') like 'hit:h1,%burn:h1%',
            'SWINGING AT A TREE WHILE ALIGHT STILL COSTS YOU');
select t_ok(t_fx(:'m','burnAtk')::int = 17,
            'for the same 15% of a maximum as any other swing');
select t_clear(:'m','h1');

-- ---- and an old match, which has no list at all -----------------------------
-- Everything in the client reads this through a default, the same way it reads
-- `acts` and `spent`. A match already in flight when 0020 lands has an fx with
-- no swings in it and must not be a crash.
select t_duel2(:'m');
select public.submit_attack(:'m','h1','g3');
update public.matches set state = jsonb_set(state, '{fx}', (state->'fx') - 'swings')
 where id = :'m';
select t_ok(t_sw(:'m') = '[]'::jsonb, 'an fx with no swings reads as an empty list');
select t_ok(t_fx(:'m','dmg')::int > 0, 'while everything the old client used is still there');

reset cn.force_parry; reset cn.force_crit;
