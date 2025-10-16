set search_path = public;

-- Robust guard:
-- - OK for service_role
-- - If profiles.is_admin exists: allow users where is_admin = true
-- - If the column doesn't exist: deny (non-admin) callers cleanly (no column error)
create or replace function public._is_admin_or_service()
returns boolean
language plpgsql
as $$
declare
  v_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
  v_uid  uuid := auth.uid();
  v_has_is_admin boolean;
begin
  -- service key / back-end
  if v_role = 'service_role' then
    return true;
  end if;

  -- does public.profiles.is_admin exist in this DB?
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'profiles'
      and column_name  = 'is_admin'
  ) into v_has_is_admin;

  if v_has_is_admin then
    return exists (
      select 1 from public.profiles p
      where p.id = v_uid and coalesce(p.is_admin, false)
    );
  end if;

  -- no is_admin column → only service_role is allowed
  return false;
end
$$;
