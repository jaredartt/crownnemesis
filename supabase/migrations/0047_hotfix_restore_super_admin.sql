-- HOTFIX: cn_is_super_admin() was overwritten during concurrent work on 0045/0046
-- (achievements + admin content overrides) to grant super-admin to ANY is_admin
-- account, dropping the "and it must be jaredartt@gmail.com" half of the check
-- from 0039, and dropping the fixed search_path guard on the SECURITY DEFINER
-- variant that replaced it. That is a real widening of who can ban users, edit
-- menu/content overrides, and everything else gated on this function alone
-- (see 0039's own comment: "every new function below this line is behind that
-- function, not behind is_admin alone"). Restored verbatim from 0039_super_admin.sql.
create or replace function public.cn_is_super_admin()
returns boolean language sql stable as $$
  select
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
    and lower(coalesce(
          nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''
        )) = 'jaredartt@gmail.com'
$$;
