-- =============================================================================
-- 0069 -- wire King Dereo's "grants the team minor (20%) resistance to
-- Knights" text to the existing hard-coded aura columns on `cards`
-- (aura_kind/aura_class/aura_pct, read by cn_aura/cn_aura_resist/
-- cn_aura_bonus -- the SAME mechanism Stelaris's team-wide effects-resist
-- aura and Miah's mage-bonus aura already use), rather than leaving Dereo's
-- ability text describing a passive that does nothing at runtime.
--
-- WHY THIS ISN'T A card_effects ROW: this project has TWO separate aura
-- mechanisms today -- the soft-code `card_effects` PASSIVE/MODIFY_STAT/
-- AURA_RESIST_EFFECTS path (Stelaris's own row, ported since) and this
-- older three-column (aura_kind/aura_class/aura_pct) path that cn_aura()
-- reads directly off the `cards` row, predating the card_effects engine.
-- Stelaris and Miah are already on the older path, so matching Dereo to
-- them (rather than inventing a second, inconsistent way to express the
-- same "team, resist damage from role X" shape) is the byte-identical,
-- least-surprise fix -- unifying both aura paths onto card_effects is a
-- separate, bigger migration than this one's scope.
-- =============================================================================
update public.cards
   set aura_kind = 'resist', aura_class = 'knight', aura_pct = 20
 where slug = 'dereo';

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  (select aura_kind = 'resist' and aura_class = 'knight' and aura_pct = 20
     from public.cards where slug = 'dereo') as dereo_aura_wired;
