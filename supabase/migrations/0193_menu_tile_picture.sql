-- 0193: an admin can upload their own picture for a menu tile.
-- Jared: "I can't upload an image to substitute a menu option."
-- NULL = the picture bundled with the build (TILES in Lobby.tsx). The file
-- itself lives in the public `art` storage bucket under menu/ (admins can
-- already write to that bucket -- see 0025_admin.sql).
alter table public.menu_sections add column if not exists art_url text;
