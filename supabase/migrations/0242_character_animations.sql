-- 0242: every character's ability / passive gets an animation (Dione & Grifo's
-- sword sweep was already set and is untouched; Dereo, Eva, Stelaris and Keidos
-- already had theirs).
--
-- 1. Three new shapes (renderer: AnimationFx.tsx): poison_cloud, shield_ward,
--    chevrons_up. 2. Sixteen catalog rows. 3. Each row's animation_slug on its
--    card_effects row. 4. Engine: a PASSIVE stat has no moment of its own, so
--    cn_attack now reports a passive's animation when the passive visibly acts in
--    an exchange (cn_passive_anims, soft-coded: the row's slug decides what plays);
--    advance_turn reports START/END_OF_TURN sentences' animations on
--    state.turnAnims {turn, anims} (Wuzu), which Board.tsx plays once per new turn.
--    Matches already in progress keep their old card snapshot (no slugs).
--
-- Applied with execute_sql + `set local lock_timeout` (apply_migration times out on
-- cn_attack/advance_turn DDL: the royale regeneration trigger runs after each).
-- NB cn_royale_ddl_watch already logs FAILED ("anchor army id not found") for every
-- cn_attack/cn_ability/advance_turn change since earlier; royale has its own functions.

alter table public.animations drop constraint if exists animations_shape_check;
alter table public.animations add constraint animations_shape_check
  check (shape in (
    'round_burst','diamond_burst','ring_pulse','arc_sweep','beam_line','pulse_only',
    'shockwave','lightning','claw_slash','meteor','starburst',
    'light_pillar','implode','whirlwind','rising_sparks','ground_crack',
    'poison_cloud','shield_ward','chevrons_up'));

insert into public.animations
 (slug,name,name_es,description,description_es,shape,color,duration_ms,particle_count,spread_deg,radius_px,scale_start,scale_end,opacity_start,opacity_end,play_at,sort)
values
 ('mako_bomb_plant','Bomb plant','Bomba colocada','The ground cracks as a bomb is buried.','El suelo se agrieta al enterrar una bomba.','ground_crack','#d9531e',800,6,360,50,0.8,1.0,1,0,'TARGET',20),
 ('fey_ember_burn','Ember burn','Quemadura de ascuas','Red embers flare up off the target.','Ascuas rojas se alzan del objetivo.','rising_sparks','#ff4d1a',1000,18,360,90,0.9,0.4,1,0,'TARGET',21),
 ('fey_fireball','Fireball','Bola de fuego','A small fireball drops onto the target.','Una pequeña bola de fuego cae sobre el objetivo.','meteor','#ff3d00',800,8,360,80,0.7,1.2,1,0,'TARGET',22),
 ('sinie_poison_cloud','Poison cloud','Nube venenosa','Green gas puffs up round the target.','Gas verde se alza alrededor del objetivo.','poison_cloud','#7bd13a',1000,9,360,70,0.6,1.3,0.9,0,'TARGET',23),
 ('sinie_venom_strike','Venom strike','Golpe venenoso','Two venomous slashes.','Dos tajos venenosos.','claw_slash','#8be04a',600,2,360,60,0.8,1.0,1,0,'TARGET',24),
 ('lumea_tornado','Tornado','Tornado','A tornado spins up on the tile.','Un tornado gira sobre la casilla.','whirlwind','#9fe8ff',1100,14,360,60,0.5,1.2,1,0,'TARGET',25),
 ('caela_swap','Swap','Intercambio','Both units are pulled into a point of light.','Ambas unidades son atraídas hacia un punto de luz.','implode','#c9a7ff',800,12,360,50,0.2,1.0,1,0,'TARGET',26),
 ('staccata_double_strike','Double strike','Doble golpe','Two quick slashes.','Dos tajos rápidos.','claw_slash','#ff9bd0',600,2,360,70,0.8,1.0,1,0,'CASTER',27),
 ('dorme_counter_ward','Counter stance','Postura de contraataque','A blue ward snaps up as the counter lands first.','Un escudo azul se alza cuando el contraataque llega primero.','shield_ward','#4aa3ff',700,0,360,60,0.8,1.0,1,0,'CASTER',28),
 ('lium_mirror_parry','Mirror parry','Parada espejo','A silver sweep turns the parry back.','Un barrido plateado devuelve la parada.','arc_sweep','#e6f0ff',600,0,200,46,0.9,2.5,1,0,'CASTER',29),
 ('nara_royal_ward','Royal ward','Escudo contra la realeza','A golden ward blocks a royal''s blow.','Un escudo dorado detiene el golpe de un rey o una reina.','shield_ward','#ffd24a',800,0,360,60,0.8,1.0,1,0,'CASTER',30),
 ('himanta_stun_stars','Stun stars','Estrellas de aturdimiento','Dizzy stars flash over the stunned unit.','Estrellas de mareo destellan sobre la unidad aturdida.','starburst','#ffe066',700,8,360,40,0.5,1.0,1,0,'TARGET',31),
 ('umiro_power_aura','Power aura','Aura de poder','Arrows of power rise over each boosted ally.','Flechas de poder suben sobre cada aliado reforzado.','chevrons_up','#ffb020',900,3,360,60,0.8,1.0,1,0,'TARGET',32),
 ('wuzu_power_surge','Power surge','Oleada de poder','Red arrows rise as Wuzu grows stronger.','Flechas rojas suben cuando Wuzu se hace más fuerte.','chevrons_up','#ff4d4d',1000,4,360,70,0.8,1.0,1,0,'CASTER',33),
 ('shu_leaf_guard','Leaf guard','Guardia de hojas','Leaves scatter as the tree takes the blow.','Las hojas saltan cuando el árbol recibe el golpe.','round_burst','#4fc26a',700,12,360,45,0.6,1.3,1,0,'TARGET',34),
 ('leos_bulwark','Bulwark','Baluarte','A steel ward closes round Leos.','Un escudo de acero se cierra alrededor de Leos.','shield_ward','#9aa8c7',800,0,360,60,0.8,1.0,1,0,'CASTER',35)
on conflict (slug) do nothing;

update public.card_effects ce set animation_slug = v.slug
from public.cards c, (values
 ('Mako','CREATE_STRUCTURE',null::text,'mako_bomb_plant'),
 ('Fey','APPLY_STATUS',null,'fey_ember_burn'),
 ('Fey','DEAL_DAMAGE',null,'fey_fireball'),
 ('Sinie','APPLY_STATUS',null,'sinie_poison_cloud'),
 ('Sinie','DEAL_DAMAGE',null,'sinie_venom_strike'),
 ('Lumea','CREATE_STRUCTURE',null,'lumea_tornado'),
 ('Caela','SWAP_POSITIONS',null,'caela_swap'),
 ('Staccata','GRANT_EXTRA_ATTACK',null,'staccata_double_strike'),
 ('Dorme','MODIFY_STAT','PARRIES','dorme_counter_ward'),
 ('Lium','MODIFY_STAT','PARRY_ALL','lium_mirror_parry'),
 ('Nara','MODIFY_STAT','IMMUNE_ROYAL','nara_royal_ward'),
 ('Himanta','MODIFY_STAT','STUNS_ON_HIT','himanta_stun_stars'),
 ('Umiro','MODIFY_STAT','NEARBY_POWER','umiro_power_aura'),
 ('Wuzu','MODIFY_STAT','POWER','wuzu_power_surge'),
 ('Shu','MODIFY_STAT','TREE_SHIELD','shu_leaf_guard'),
 ('Leos','MODIFY_STAT','MAX_HITS_PER_TURN','leos_bulwark')) v(cname, act, stat, slug)
where c.id = ce.card_id and c.name = v.cname and ce.action = v.act and (v.stat is null or ce.stat_name = v.stat);

create or replace function public.cn_passive_slug(p_unit jsonb, p_stat text)
returns text language sql immutable set search_path = public as $$
  select coalesce((select r->>'animation_slug'
    from jsonb_array_elements(case when jsonb_typeof(p_unit->'abilityScript') = 'array' then p_unit->'abilityScript' else '[]'::jsonb end) r
   where r->>'trigger' = 'PASSIVE' and r->>'action' = 'MODIFY_STAT' and r->>'stat_name' = p_stat
     and coalesce(r->>'animation_slug', '') <> '' limit 1), '')
$$;

create or replace function public.cn_queue_anim(p_state jsonb, p_slug text, p_by jsonb, p_targets jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare v_t jsonb := '[]'::jsonb; t jsonb;
begin
  if coalesce(p_slug, '') = '' or p_by is null then return p_state; end if;
  for t in select * from jsonb_array_elements(coalesce(p_targets, '[]'::jsonb)) loop
    if t is not null and t->>'x' is not null then
      v_t := v_t || jsonb_build_array(jsonb_build_object('id', t->>'id', 'x', (t->>'x')::int, 'y', (t->>'y')::int));
    end if;
  end loop;
  return jsonb_set(p_state, '{animQueue}',
    coalesce(p_state->'animQueue', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'slug', p_slug,
      'by', jsonb_build_object('id', p_by->>'id', 'x', (p_by->>'x')::int, 'y', (p_by->>'y')::int),
      'targets', v_t)), true);
end $$;

create or replace function public.cn_passive_anims(
  p_state jsonb, p_atk jsonb, p_tgt jsonb, p_shield_for jsonb, p_tree jsonb, p_counter int, p_parries int)
returns jsonb language plpgsql set search_path = public as $$
declare
  st jsonb := p_state; slug text; a jsonb; fin jsonb; k int; strk jsonb; defn jsonb; rng int;
begin
  begin
    if p_shield_for is not null and p_tree is not null then
      slug := cn_passive_slug(p_shield_for, 'TREE_SHIELD');
      st := cn_queue_anim(st, slug, p_shield_for, jsonb_build_array(p_tree, p_shield_for));
    end if;
    if p_tgt is not null and p_atk is not null and p_tgt->>'owner' <> p_atk->>'owner' then
      st := cn_queue_anim(st, cn_passive_slug(p_tgt, 'MAX_HITS_PER_TURN'), p_tgt, jsonb_build_array(p_tgt));
      if cn_immune(p_tgt, p_atk) then
        st := cn_queue_anim(st, cn_passive_slug(p_tgt, 'IMMUNE_' || upper(coalesce(p_atk->>'role', ''))), p_tgt, jsonb_build_array(p_tgt));
      end if;
      if coalesce((p_tgt->>'parries')::boolean, false) and coalesce(p_counter, 0) > 0 then
        st := cn_queue_anim(st, cn_passive_slug(p_tgt, 'PARRIES'), p_tgt, jsonb_build_array(p_tgt));
      end if;
      if coalesce(p_parries, 0) > 0 then
        if coalesce((p_tgt->>'parryAll')::boolean, false) then
          st := cn_queue_anim(st, cn_passive_slug(p_tgt, 'PARRY_ALL'), p_tgt, jsonb_build_array(p_tgt));
        end if;
        if coalesce((p_atk->>'parryAll')::boolean, false) then
          st := cn_queue_anim(st, cn_passive_slug(p_atk, 'PARRY_ALL'), p_atk, jsonb_build_array(p_atk));
        end if;
      end if;
      for k in 1..2 loop
        strk := case when k = 1 then p_atk else p_tgt end;
        defn := case when k = 1 then p_tgt else p_atk end;
        if coalesce((strk->>'stuns')::boolean, false) then
          select u into fin from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) u where u->>'id' = defn->>'id' limit 1;
          if fin is not null and cn_stunned(fin) then
            st := cn_queue_anim(st, cn_passive_slug(strk, 'STUNS_ON_HIT'), strk, jsonb_build_array(fin));
          end if;
        end if;
      end loop;
      for k in 1..2 loop
        strk := case when k = 1 then p_atk else p_tgt end;
        continue when k = 2 and coalesce(p_counter, 0) <= 0;
        if cn_near_power(st, strk) > 0 then
          for a in select u from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) u
                    where u->>'owner' = strk->>'owner' and u->>'id' <> strk->>'id' and (u->>'hp')::int > 0
                      and cn_passive_slug(u, 'NEARBY_POWER') <> '' loop
            select coalesce(max(case when r->>'range_kind' = 'FIXED_RANGE' then coalesce((r->>'range_max')::int, 1) else 1 end), 1)
              into rng from jsonb_array_elements(a->'abilityScript') r
             where r->>'trigger' = 'PASSIVE' and r->>'stat_name' = 'NEARBY_POWER';
            if cn_cheb((a->>'x')::int, (a->>'y')::int, (strk->>'x')::int, (strk->>'y')::int) between 1 and rng then
              st := cn_queue_anim(st, cn_passive_slug(a, 'NEARBY_POWER'), a, jsonb_build_array(strk));
            end if;
          end loop;
        end if;
      end loop;
    end if;
  exception when others then
    return p_state;
  end;
  return st;
end $$;

-- cn_passive_anims(state, atk, tgt, shield_for, tree, counter, parries): see the
-- header. TREE_SHIELD, MAX_HITS_PER_TURN, IMMUNE_<role>, PARRIES, PARRY_ALL,
-- STUNS_ON_HIT (over whoever ended up stunned), NEARBY_POWER (each aura-bearer in
-- range of a boosted striker, onto the striker). Everything is swallowed on error.

-- cn_attack: declare v_shield_for; set it where the shield redirects; call
--   v_st := cn_passive_anims(v_st, v_atk, v_tgt, v_shield_for, v_shield, v_counter, v_parries);
-- right before `v_pass_anims := coalesce(v_st->'animQueue', ...)`.
-- advance_turn(uuid,text,boolean): END_OF_TURN / START_OF_TURN cn_run_effects calls pass
--   'collectAnims', true; before `st := jsonb_set(st, '{active}', 'null')` the queue is
--   moved to st.turnAnims = {turn, anims} and animQueue is stripped.
