-- 0209: bots plant Mako's bomb with a plan instead of at random.
--
-- WHY IT LOOKED RANDOM. For a tile ability (Mako's bomb, Lumea's tornado) the 1v1
-- bot scores every adjacent tile identically -- cn_bot_strategy_bonus handed Mako
-- cn_bot_wall_tile_bonus(.., p_vx, p_vy, ..), and p_vx/p_vy is where MAKO STANDS,
-- not where the bomb goes -- so the tile itself was decided by noise alone, and
-- often landed in the bot's own back row, next to its own king (when a bomb is
-- destroyed it burns every unit within 1, so that is a bomb aimed at yourself).
-- And only Expert (level 3) got any strategy at all; Medium bots (level 2) picked
-- the tile purely at random.
--
-- THE RULE NOW (cn_bot_bomb_tile_bonus, scores the BOMB'S tile):
--   - never beside your own units: -90 each, -220 for the king (it burns them);
--   - on your king's side of the enemies, close to them, so it blocks their way
--     and anything that steps on it eats 30 + burn (+40 per enemy beside it, they
--     burn if they shoot it);
--   - nearer the fight than the back row, a little pull to the middle;
--   - not tucked in your own corner when nothing is near (-60).
-- Expert gets the full bonus, Medium 60% of it, Easy stays loose.
create or replace function public.cn_bot_bomb_tile_bonus(v_st jsonb, p_side text, u jsonb, p_tile text)
 returns numeric
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_tx int; v_ty int;
  v_w int := coalesce((v_st->'board'->>'w')::int, 6);
  v_h int := coalesce((v_st->'board'->>'h')::int, 8);
  v_king jsonb; q jsonb; d int; v_kd int := 99; v_qkd int; v_cd int;
  v_own_pen numeric := 0; v_en_adj int := 0; v_near int := 99; v_block numeric := 0;
begin
  if p_tile is null or left(p_tile, 1) <> '@' then return 0; end if;
  v_tx := split_part(substr(p_tile, 2), ',', 1)::int;
  v_ty := split_part(p_tile, ',', 2)::int;

  for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    continue when (q->>'hp')::int <= 0;
    if q->>'owner' = p_side and coalesce((q->>'royal')::boolean, false) then v_king := q; end if;
  end loop;
  if v_king is not null then
    v_kd := cn_cheb(v_tx, v_ty, (v_king->>'x')::int, (v_king->>'y')::int);
  end if;
  v_cd := cn_cheb(v_tx, v_ty, v_w / 2, v_h / 2);

  for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    continue when (q->>'hp')::int <= 0;
    d := cn_cheb(v_tx, v_ty, (q->>'x')::int, (q->>'y')::int);
    if q->>'owner' = p_side then
      continue when q->>'id' = u->>'id';
      if d <= 1 then
        v_own_pen := v_own_pen + case when coalesce((q->>'royal')::boolean, false) then 220 else 90 end;
      end if;
    else
      if d <= 1 then v_en_adj := v_en_adj + 1; end if;
      v_near := least(v_near, d);
      if v_king is not null then
        v_qkd := cn_cheb((q->>'x')::int, (q->>'y')::int, (v_king->>'x')::int, (v_king->>'y')::int);
        if v_kd < v_qkd then
          v_block := greatest(v_block,
            case when coalesce((q->>'rmax')::int, 1) <= 1 then 40 else 25 end
            + case when coalesce((q->>'royal')::boolean, false) or q->>'slug' in ('dione-grifo', 'lium') then 20 else 0 end
            + greatest(0, 6 - d) * 8);
        end if;
      end if;
    end if;
  end loop;

  return greatest(-250,
    v_block
    + least(v_en_adj, 3) * 40
    + greatest(0, 6 - v_near) * 7
    + greatest(0, 4 - v_cd) * 6
    - v_own_pen
    - case when v_king is not null and v_kd <= 2 and v_near >= 4 then 60 else 0 end);
end
$function$;

-- Patch the two callers in place (replace on their current definitions).
do $patch$
declare
  v_def text; v_new text;
  a1 text := E'elsif v_slug = ''mako'' and p_kind = ''ability'' and p_target_id is not null and left(p_target_id, 1) = ''@''\n        and v_my_king is not null then\n    v_bonus := v_bonus + cn_bot_wall_tile_bonus(v_st, v_my_king, v_opp, p_vx, p_vy, v_threat, v_threat_d);';
  b1 text := E'elsif v_slug = ''mako'' and p_kind = ''ability'' and p_target_id is not null and left(p_target_id, 1) = ''@'' then\n    v_bonus := v_bonus + cn_bot_bomb_tile_bonus(v_st, p_side, u, p_target_id);';
  a2 text := E'v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, ''ability'', vx, vy, v_ab_tile) else 0 end;';
  b2 text := E'v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, ''ability'', vx, vy, v_ab_tile)\n                                 when v_lvl = 2 and u->>''slug'' = ''mako'' then 0.6 * cn_bot_bomb_tile_bonus(st, p_side, u, v_ab_tile)\n                                 else 0 end;';
begin
  v_def := pg_get_functiondef('public.cn_bot_strategy_bonus(jsonb,text,jsonb,text,integer,integer,text)'::regprocedure);
  v_new := replace(v_def, a1, b1);
  if v_new = v_def then raise exception 'cn_bot_strategy_bonus anchor not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  v_new := replace(v_def, a2, b2);
  if v_new = v_def then raise exception 'bot_step anchor not found'; end if;
  execute v_new;
end
$patch$;
