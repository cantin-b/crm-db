set search_path = public;

-- Keep the same guard helper (already created in 025/earlier); create it if missing.
create or replace function public._is_admin_or_service()
returns boolean
language plpgsql
as $$
declare
  v_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
  v_uid  uuid := auth.uid();
begin
  if v_role = 'service_role' then
    return true;
  end if;
  return exists (
    select 1 from public.profiles p
    where p.id = v_uid and coalesce(p.is_admin, false)
  );
end
$$;

-- (1) TRUNCATE ONLY the staging table, NO CASCADE
create or replace function public.staging_raw_prospects_truncate()
returns table(truncated boolean, deleted_rows bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cnt bigint;
begin
  if not public._is_admin_or_service() then
    raise exception 'not allowed';
  end if;

  select count(*) into v_cnt from public.staging_raw_prospects;

  -- No CASCADE: we only reset this table’s identity.
  execute 'truncate table public.staging_raw_prospects restart identity';

  return query select true, v_cnt;
end
$$;

grant execute on function public.staging_raw_prospects_truncate()
  to authenticated, service_role;

-- (2) Clear only one batch; if table becomes empty, reset identity safely
create or replace function public.staging_raw_prospects_clear_batch(p_batch_label text)
returns table(deleted_rows bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cnt bigint;
  v_left bigint;
  v_seq text;
begin
  if not public._is_admin_or_service() then
    raise exception 'not allowed';
  end if;

  delete from public.staging_raw_prospects s
  where s.batch_label = p_batch_label;
  GET DIAGNOSTICS v_cnt = ROW_COUNT;

  select count(*) into v_left from public.staging_raw_prospects;

  -- If the table is empty, reset the identity/sequence (if any).
  if v_left = 0 then
    select pg_get_serial_sequence('public.staging_raw_prospects','id') into v_seq;
    if v_seq is not null then
      perform setval(v_seq, 1, false);
    end if;
  end if;

  return query select v_cnt;
end
$$;

grant execute on function public.staging_raw_prospects_clear_batch(text)
  to authenticated, service_role;
