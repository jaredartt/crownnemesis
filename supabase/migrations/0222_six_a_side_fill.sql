-- 0222 - give every finished five-card kingdom a sixth card (see 0221).
-- Jared: "just add a random unit to all players' decks for now, so that their
-- decks don't break rules". Only a kingdom that was a complete, legal five (one
-- royal, all cards live) is touched: it gets one random active non-royal card it
-- does not already have (never a test card). Half-built kingdoms stay as they
-- are. profiles.deck is re-synced from the selected kingdom afterwards.
update public.profiles p
   set kingdoms = (
     select coalesce(jsonb_agg(
       case
         when jsonb_array_length(k->'deck') = 5
          and public.deck_royals(array(select jsonb_array_elements_text(k->'deck'))) = 1
         then jsonb_set(k, '{deck}',
                (k->'deck') || to_jsonb((
                  select c.slug from public.cards c
                   where c.is_active and not c.royal and not c.is_test_card and c.slug is not null
                     and not (c.slug = any(array(select jsonb_array_elements_text(k->'deck'))))
                   order by random() limit 1)))
         else k
       end order by ord), '[]'::jsonb)
     from jsonb_array_elements(p.kingdoms) with ordinality as t(k, ord))
 where jsonb_typeof(p.kingdoms) = 'array' and jsonb_array_length(p.kingdoms) > 0;

update public.profiles set deck = public.selected_deck(id)
 where jsonb_typeof(kingdoms) = 'array' and jsonb_array_length(kingdoms) > 0;
