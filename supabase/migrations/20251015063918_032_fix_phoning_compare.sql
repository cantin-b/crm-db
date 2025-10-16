set search_path = public;

-- 0) Drop toutes les surcharges existantes pour repartir propre
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, oidvectortypes(p.proargtypes) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'campaign_create_from_filters'
  loop
    execute format('drop function if exists %I.%I(%s);', r.nspname, r.proname, r.args);
  end loop;
end$$;

-- 1) Recreate: version unique avec comparaison PHONING en TEXT
create function public.campaign_create_from_filters(
  p_name text,
  p_batch_ids bigint[],
  p_geo text,
  p_min_salary numeric,
  p_max_salary numeric,
  p_require_email boolean,
  p_require_coborrower boolean,
  p_phoning_status text[],
  p_employment public.employment_status_enum[],
  p_housing public.housing_status_enum[],
  p_member_ids uuid[],
  p_include_employment_null boolean default false,
  p_include_housing_null boolean default false
)
returns table(campaign_id bigint, created_targets integer, created_members integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_campaign_id bigint;
  v_created_targets int := 0;
  v_created_members int := 0;
  v_uid uuid := auth.uid();

  v_phone_text text[] := '{}';
  v_want_phone_null boolean := false;
begin
  -- ✅ Garde: service_role OU manager/admin applicatif
  if not (public._is_admin_or_service() or public.is_manager_or_admin()) then
    raise exception 'not allowed';
  end if;

  -- Prétraitement phoning
  if p_phoning_status is not null then
    v_want_phone_null := array_position(p_phoning_status, '__NULL__') is not null;
    v_phone_text := array_remove(p_phoning_status, '__NULL__');
  end if;

  -- Créer la campagne
  insert into public.campaigns(name, status, created_by)
  values (p_name, 'INACTIVE', v_uid)
  returning id into v_campaign_id;

  -- Membres (facultatif)
  if p_member_ids is not null then
    insert into public.campaign_members(campaign_id, user_id)
    select v_campaign_id, u from unnest(p_member_ids) u
    on conflict do nothing;
    get diagnostics v_created_members = row_count;
  end if;

  -- Construire prospects éligibles
  with base as (
    select p.id as prospect_id
    from public.prospects p
    where
      (p_batch_ids is null or array_length(p_batch_ids,1) is null or p.list_batch_id = any(p_batch_ids))
      and (
        p_geo is null
        or (p_geo = 'FR_METRO' and p.geo_zone in ('IDF','PROVINCE'))
        or (p_geo = 'IDF'      and p.geo_zone = 'IDF')
        or (p_geo = 'PROVINCE' and p.geo_zone = 'PROVINCE')
      )
      and (p_min_salary is null or p.net_salary >= p_min_salary)
      and (p_max_salary is null or p.net_salary <= p_max_salary)
      and (
        coalesce(p_require_email,false) = false
        or (p.email is not null and length(trim(p.email)) > 0)
      )
      and (
        p_require_coborrower is null
        or (p_require_coborrower = true  and coalesce(p.co_borrower,false) = true)
        or (p_require_coborrower = false and coalesce(p.co_borrower,false) = false)
      )
      and (
        p_phoning_status is null
        or (v_want_phone_null and p.phoning_disposition is null)
        or (
          array_length(v_phone_text,1) is not null
          and p.phoning_disposition::text = any(v_phone_text)
        )
      )
      and (
        p_employment is null
        or p.employment_status = any(p_employment)
        or (p_include_employment_null and p.employment_status is null)
      )
      and (
        p_housing is null
        or p.housing_status = any(p_housing)
        or (p_include_housing_null and p.housing_status is null)
      )
  )
  insert into public.campaign_targets(campaign_id, prospect_id)
  select v_campaign_id, b.prospect_id
  from base b
  left join public.campaign_targets ct
    on ct.campaign_id = v_campaign_id
   and ct.prospect_id = b.prospect_id
  where ct.prospect_id is null;

  get diagnostics v_created_targets = row_count;

  return query select v_campaign_id, v_created_targets, v_created_members;
end
$$;

-- Droits
revoke all on function public.campaign_create_from_filters(
  text,bigint[],text,numeric,numeric,boolean,boolean,text[],
  public.employment_status_enum[],public.housing_status_enum[],uuid[],boolean,boolean
) from public;

grant execute on function public.campaign_create_from_filters(
  text,bigint[],text,numeric,numeric,boolean,boolean,text[],
  public.employment_status_enum[],public.housing_status_enum[],uuid[],boolean,boolean
) to authenticated, service_role;
