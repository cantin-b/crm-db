set search_path = public;

-- Remplace la RPC pour poser owner_id lors de la création
drop function if exists public.campaign_create_from_filters(
  text,bigint[],text,numeric,numeric,boolean,boolean,text[],
  public.employment_status_enum[],public.housing_status_enum[],uuid[],boolean,boolean
);

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

  v_member_ids uuid[] := '{}';
  v_member_count int := 0;

  v_phone_text text[] := '{}';
  v_want_phone_null boolean := false;
begin
  -- garde
  if not (public._is_admin_or_service() or public.is_manager_or_admin()) then
    raise exception 'not allowed';
  end if;

  -- phoning preprocess (on compare en text)
  if p_phoning_status is not null then
    v_want_phone_null := array_position(p_phoning_status, '__NULL__') is not null;
    v_phone_text := array_remove(p_phoning_status, '__NULL__');
  end if;

  -- 1) campagne
  insert into public.campaigns(name, status, created_by)
  values (p_name, 'INACTIVE', v_uid)
  returning id into v_campaign_id;

  -- 2) membres
  if p_member_ids is not null and array_length(p_member_ids,1) is not null then
    insert into public.campaign_members(campaign_id, user_id)
    select distinct v_campaign_id, u from unnest(p_member_ids) u
    on conflict do nothing;
    get diagnostics v_created_members = row_count;

    select array_agg(distinct u order by u) into v_member_ids
    from unnest(p_member_ids) u;
  end if;
  v_member_count := coalesce(array_length(v_member_ids,1),0);

  -- 3) base éligible
  with base as (
    select p.id as prospect_id, p.owner_id
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
        or (array_length(v_phone_text,1) is not null and p.phoning_disposition::text = any(v_phone_text))
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
  ),
  -- numérotation pour round-robin sur ceux SANS owner
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
    -- a) on conserve l'owner existant
    select b.prospect_id, b.owner_id as chosen
    from base b
    where b.owner_id is not null

    union all

    -- b) on attribue un owner si possible (RR sur la liste fournie)
    select n.prospect_id,
           case when v_member_count > 0
                then (select m.m_id from members m
                      where m.ord = ((n.rn - 1) % v_member_count) + 1)
                else null::uuid
           end as chosen
    from numbered n
  )
  -- 4) poser/miroiter l'affectation
  , up_owner as (
    update public.prospects p
       set owner_id = d.chosen
    from dispatch d
    where p.id = d.prospect_id
      and p.owner_id is null        -- ne jamais écraser
      and d.chosen is not null
    returning p.id
  )
  , ins_targets as (
    insert into public.campaign_targets(campaign_id, prospect_id, assigned_to)
    select v_campaign_id, d.prospect_id, d.chosen
    from dispatch d
    left join public.campaign_targets ct
      on ct.campaign_id = v_campaign_id
     and ct.prospect_id = d.prospect_id
    where ct.prospect_id is null
    returning 1
  )
  -- 5) synchroniser le miroir: assigned_to = owner_id
  update public.campaign_targets ct
     set assigned_to = p.owner_id
  from public.prospects p
  where ct.campaign_id = v_campaign_id
    and ct.prospect_id = p.id
    and (ct.assigned_to is distinct from p.owner_id);

  get diagnostics v_created_targets = row_count;

  return query select v_campaign_id, v_created_targets, v_created_members;
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
