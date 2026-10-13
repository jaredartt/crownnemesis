-- 0251: the "b4" expert-bot brain goes live (level 3).
-- Hooks (bot_step -> bot4_step, cn_bot_army -> cn_b4_place, throw guard) are in 0250.
-- Rollback: update bot_brains set is_live=false where level=3 and is_live;
--           update bot_brains set is_live=true where id='b737de5c-2193-419a-958f-9ca6120c05f9';  -- previous classic expert
insert into bot_brains(label, level, weights, is_live, parent_id, notes)
select 'expert-b4 (look-ahead, purposeful deployment)', 3,
  weights || jsonb_build_object('engine','b4','place','b4','opp_king_mult',2,'king_danger',0.5,
   'place_archetypes', '[ {}, {"king_guard":24,"king_open":13,"front_depth":22,"rng_depth":12,"carry_depth":4}, {"king_back":8,"rng_depth":8,"carry_depth":18,"front_depth":30,"cap_front":16,"cohesion":3} ]'::jsonb),
  false, id, 'b4 engine: one-reply look-ahead via rollouts, ability/combo aware, formation planner.'
from bot_brains where level=3 and is_live
  and not exists (select 1 from bot_brains where label like 'expert-b4%');
with old as (update bot_brains set is_live=false where level=3 and is_live and coalesce(weights->>'engine','')<>'b4' returning id)
update bot_brains set is_live=true where label like 'expert-b4%' and exists (select 1 from old);
