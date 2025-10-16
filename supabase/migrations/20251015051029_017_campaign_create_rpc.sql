set search_path = public;

create or replace function public.campaign_create_from_filters(
  p_name text,
  p_batch_ids bigint[],                    -- lots sélectionnés
  p_geo text default 'FR_METRO',           -- 'IDF' | 'PROVINCE' | 'FR_METRO'
  p_min_salary numeric default null,
  p_max_salary numeric default null,
  p_require_email boolean default false,   -- true = uniquement avec email
  p_require_coborrower boolean default null, -- true/false/null (indifférent)
  p_phoning_status text[] default null,    -- ex: ['__NULL__','A_RAPPELER','NRP']
  p_employment employment_status_enum[] default null,
  p_housing housing_status_enum[] default null,
  p_member_ids uuid[] default null         -- opérateurs à affecter (round-robin)
)
returns table(campaign_id bigint, targets_inserted int)
language plpgsql
security definer
set search_path = public
as $$
declare v_cid bigint;
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception 'Nom de campagne requis';
  end if;
  if p_batch_ids is null or array_length(p_batch_ids,1) is null then
    raise exception 'Au moins un lot (list_batch) est requis';
  end if;

  insert into public.campaigns(name, start_at, filter_json, created_by, status)
  values (
    p_name,
    current_date,
    jsonb_build_object(
      'batches', p_batch_ids,
      'geo', p_geo,
      'salary', jsonb_build_object('min', p_min_salary, 'max', p_max_salary),
      'require_email', p_require_email,
      'require_coborrower', p_require_coborrower,
      'phoning_status', p_phoning_status,
      'employment', p_employment,
      'housing', p_housing
    ),
    auth.uid(),
    'INACTIVE'::campaign_status_enum   -- ⬅️ toujours créée « non active »
  )
  returning id into v_cid;

  -- membres (optionnel)
  if p_member_ids is not null then
    insert into public.campaign_members(campaign_id, user_id)
    select v_cid, unnest(p_member_ids)
    on conflict do nothing;
  end if;

  with params as (
    select
      case
        when upper(p_geo) = 'IDF' then array['IDF']::text[]
        when upper(p_geo) = 'PROVINCE' then array['PROVINCE']::text[]
        else array['IDF','PROVINCE']::text[]   -- FR_METRO
      end as wanted_geo
  ),
  base as (
    select p.id
    from public.prospects p
    join params on true
    where p.list_batch_id = any(p_batch_ids)
      and p.geo_zone::text = any(params.wanted_geo)
      and (p_min_salary is null or (p.net_salary is not null and p.net_salary >= p_min_salary))
      and (p_max_salary is null or (p.net_salary is not null and p.net_salary <= p_max_salary))
      and (p_require_email = false or (p.email is not null and p.email <> ''))
      and (p_require_coborrower is null or p.co_borrower = p_require_coborrower)
      and (
        p_phoning_status is null
        or (
          ('__NULL__' = any(p_phoning_status) and p.phoning_disposition is null)
          or (p.phoning_disposition::text = any(p_phoning_status))
        )
      )
      and (p_employment is null or p.employment_status = any(p_employment))
      and (p_housing    is null or p.housing_status    = any(p_housing))
  ),
  to_insert as (
    select
      v_cid as campaign_id,
      b.id  as prospect_id,
      case
        when p_member_ids is null or array_length(p_member_ids,1) is null then null
        else p_member_ids[(row_number() over (order by b.id) - 1) % array_length(p_member_ids,1) + 1]
      end as assigned_to
    from base b
  ),
  ins as (
    insert into public.campaign_targets(campaign_id, prospect_id, assigned_to)
    select campaign_id, prospect_id, assigned_to from to_insert
    on conflict (campaign_id, prospect_id) do nothing
    returning 1
  )
  select v_cid, coalesce(count(*),0)::int
  into campaign_id, targets_inserted
  from ins;

  return;
end $$;
