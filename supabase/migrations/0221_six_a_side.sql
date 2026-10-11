-- ===========================================================================
--  0221 - six a side: a kingdom is 6 cards (5 units + 1 royal)
--
--  Jared: "from now on, kingdoms are 6 cards decks (5 units + 1 royal)".
--
--  deck_size() is the one place the number lives (see 0015, which went from
--  four to five the same way): set_deck / save_kingdom / deck_of / default_deck /
--  random_deck / cn_army / cn_royale_army / cn_clean_kingdoms all ask it. The
--  royal count stays exactly one, so units = deck_size() - 1 = 5.
--
--  No data migration. Every saved kingdom is five cards today, which is now
--  one short: save_kingdom keeps a half-built deck, the picker shows it as
--  "pick 1 more", and until it is finished deck_of() hands back default_deck()
--  (the roster's first royal + the first five other cards by sort) -- exactly
--  what 0015 did. Matches already in progress keep the units they were dealt.
--  Board room: each 1v1 half is 6x4 = 24 tiles, each Battle Royale quarter is
--  3x4 = 12, both big enough for six.
-- ===========================================================================
create or replace function public.deck_size() returns int
language sql immutable as $$ select 6 $$;
