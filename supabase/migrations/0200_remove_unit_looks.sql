-- 0200: remove the unit looks (rims / glows / shimmers around units on the board).
-- Jared: "Remove all the unit frames thing, it's distracting." Removed completely.
-- Checked first: no Shop purchases of a unit look existed (nothing to refund),
-- 4 legacy grants, 1 player had one equipped.
-- profiles.equipped_unit_skin and skins.kind = 'unit' stay in the schema, unused.
update public.profiles set equipped_unit_skin = null where equipped_unit_skin is not null;
delete from public.user_skins where skin_id in (select id from public.skins where kind = 'unit');
delete from public.skins where kind = 'unit';
