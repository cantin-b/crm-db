set search_path = public;

-- Drop any existing overloads to recreate a single, clean signature
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

create function public.campaign_create_from_filters(
  p_name text,
  p_batch_ids bigint[],
  p_geo text,
  p_min_salary numeric,
  p_max_salary numeric,
  p_require_email boolean,
  p_require_coborrower boolean,
  p_phoning_status text[],                          -- may contain '__NULL__'
  p_employment public.employment_status_enum[],
  p_housing public.housing_status_enum[],
  p_member_ids uuid[],                              -- operators to assign (any role)
  p_include_employment_null boolean default false,  -- include NULL employment
  p_include_housing_null boolean default false      -- include NULL housing
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

  -- phoning filter pre-processing (TEXT compare)
  v_phone_text text[] := '{}';
  v_want_phone_null boolean := false;

  -- round-robin state
  v_member_ids uuid[] := '{}';
  v_member_count int := 0;
begin
  -- Allow service_role OR app managers/admins
  if not (public._is_admin_or_service() or public.is_manager_or_admin()) then
    raise exception 'not allowed';
  end if;

  -- phoning filter: separate NULL from values
  if p_phoning_status is not null then
    v_want_phone_null := array_position(p_phoning_status, '__NULL__') is not null;
    v_phone_text := array_remove(p_phoning_status, '__NULL__');
  end if;

  -- create campaign shell
  insert into public.campaigns(name, status, created_by)
  values (p_name, 'INACTIVE', v_uid)
  returning id into v_campaign_id;

  -- store members (optional) and prep RR data
  if p_member_ids is not null and array_length(p_member_ids,1) is not null then
    insert into public.campaign_members(campaign_id, user_id)
    select distinct v_campaign_id, u
    from unnest(p_member_ids) as u
    on conflict do nothing;
    get diagnostics v_created_members = row_count;

    v_member_ids := (select array_agg(distinct u order by u) from unnest(p_member_ids) u);
  else
    v_member_ids := '{}';
  end if;
  v_member_count := coalesce(array_length(v_member_ids,1), 0);

  -- build eligible set (include owner_id to preserve if present)
  with base as (
    select p.id as prospect_id, p.owner_id
    from public.prospects p
    where
      -- lists filter (empty -> no filter)
      (p_batch_ids is null or array_length(p_batch_ids,1) is null or p.list_batch_id = any(p_batch_ids))
      -- geo
      and (
        p_geo is null
        or (p_geo = 'FR_METRO' and p.geo_zone in ('IDF','PROVINCE'))
        or (p_geo = 'IDF'      and p.geo_zone = 'IDF')
        or (p_geo = 'PROVINCE' and p.geo_zone = 'PROVINCE')
      )
      -- salary range
      and (p_min_salary is null or p.net_salary >= p_min_salary)
      and (p_max_salary is null or p.net_salary <= p_max_salary)
      -- email requirement (binary)
      and (
        coalesce(p_require_email,false) = false
        or (p.email is not null and length(trim(p.email)) > 0)
      )
      -- co-borrower requirement (tri-state)
      and (
        p_require_coborrower is null
        or (p_require_coborrower = true  and coalesce(p.co_borrower,false) = true)
        or (p_require_coborrower = false and coalesce(p.co_borrower,false) = false)
      )
      -- phoning disposition (TEXT compare + optional NULL)
      and (
        p_phoning_status is null
        or (v_want_phone_null and p.phoning_disposition is null)
        or (
          array_length(v_phone_text,1) is not null
          and p.phoning_disposition::text = any(v_phone_text)
        )
      )
      -- employment (enums + optional NULL)
      and (
        p_employment is null
        or p.employment_status = any(p_employment)
        or (p_include_employment_null and p.employment_status is null)
      )
      -- housing (enums + optional NULL)
      and (
        p_housing is null
        or p.housing_status = any(p_housing)
        or (p_include_housing_null and p.housing_status is null)
      )
  ),
  -- only number prospects WITHOUT owner (those we must distribute)
  numbered as (
    select prospect_id, row_number() over (order by prospect_id) as rn
    from base
    where owner_id is null
  ),
  members as (
    select m_id, ord::int
    from unnest(v_member_ids) with ordinality as t(m_id, ord)
  ),
  dispatch as (
    -- keep existing owner
    select b.prospect_id, b.owner_id as assigned_to
    from base b
    where b.owner_id is not null

    union all

    -- RR for those without owner (or NULL if no members)
    select n.prospect_id,
           case when v_member_count > 0
                then (select m.m_id
                      from members m
                      where m.ord = ((n.rn - 1) % v_member_count) + 1)
                else null::uuid
           end as assigned_to
    from numbered n
  )
  insert into public.campaign_targets(campaign_id, prospect_id, assigned_to)
  select v_campaign_id, d.prospect_id, d.assigned_to
  from dispatch d
  left join public.campaign_targets ct
    on ct.campaign_id = v_campaign_id
   and ct.prospect_id = d.prospect_id
  where ct.prospect_id is null;

  get diagnostics v_created_targets = row_count;

  return query
    select v_campaign_id, v_created_targets, v_created_members;
end
$$;

revoke all on function public.campaign_create_from_filters(
  text,bigint[],text,numeric,numeric,boolean,boolean,text[],
  public.employment_status_enum[],public.housing_status_enum[],uuid[],boolean,boolean
) from public;

grant execute on function public.campaign_create_from_filters(
  text,bigint[],text,numeric,numeric,boolean,boolean,text[],
  public.employment_status_enum[],public.housing_status_enum[],uuid[],boolean,boolean
) to authenticated, service_role;
