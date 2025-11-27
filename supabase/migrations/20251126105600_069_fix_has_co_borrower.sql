BEGIN;

------------------------------------------------------------
-- 1) import_prospects_from_staging (v1 sans p_is_public)
--    co_borrower → has_co_borrower
------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.import_prospects_from_staging(
  p_batch_label text DEFAULT NULL::text,
  p_obtained_on date DEFAULT CURRENT_DATE,
  p_source source_enum DEFAULT NULL::source_enum
)
RETURNS TABLE(list_batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_batch_id bigint;
begin
  insert into public.list_batches(label, obtained_on, source, size_hint)
  values (
    coalesce(nullif(p_batch_label,''), 'IMPORT_'||to_char(now(),'YYYYMMDD-HH24MISS')),
    p_obtained_on,
    p_source,
    (select count(*) from public.staging_raw_prospects)
  )
  returning id into v_batch_id;

  with src as (
    select
      nullif(trim(first_name),'')                            as first_name,
      nullif(trim(last_name),'')                             as last_name,
      public.normalize_email(email)                          as email_norm,
      public.normalize_fr_phone(phone)                       as phone_norm,
      nullif(upper(trim(civility)),'')                       as civility_norm,
      to_date(nullif(birth_date,''),'YYYY-MM-DD')            as birth_norm,
      nullif(trim(address1),'')                              as address1_norm,
      nullif(trim(address2),'')                              as address2_norm,
      public.normalize_cp(postal_code)                       as postal_code_norm,
      nullif(trim(city),'')                                  as city_norm,
      nullif(regexp_replace(net_salary,'[^\\d.,]','','g'),'')::numeric    as net_salary_norm,
      public.parse_bool(co_borrower)                         as co_borrower_norm,
      nullif(regexp_replace(co_net_salary,'[^\\d.,]','','g'),'')::numeric as co_net_salary_norm,
      nullif(trim(comments),'')                              as comments_norm,
      nullif(trim(annexes),'')                               as annexes_norm,
      coalesce(public.parse_bool(annexes_private), false)    as annexes_private_norm,
      case upper(trim(source))
        when 'PARRAINAGE'    then 'PARRAINAGE'::source_enum
        when 'LEAD'          then 'LEAD'::source_enum
        when 'LISTE_ACHETEE' then 'LISTE_ACHETEE'::source_enum
        else null end                                         as source_enum_norm
    from public.staging_raw_prospects
  ),
  filtered as (
    select * from src
    where first_name is not null
      and last_name  is not null
      and (phone_norm is not null or email_norm is not null)
  ),
  dedup as (
    select f.*
      from filtered f
     where not exists (
       select 1 from public.prospects p
        where (f.phone_norm is not null and p.phone_e164 = f.phone_norm)
           or (f.email_norm is not null and p.email      = f.email_norm)
     )
  )
  insert into public.prospects (
    list_batch_id, first_name, last_name, email, phone_e164,
    civility, birth_date,
    address1, address2, postal_code, city,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    source, stage
  )
  select
    v_batch_id,
    first_name, last_name, email_norm, phone_norm,
    public.normalize_civility(civility_norm),
    birth_norm,
    address1_norm, address2_norm, postal_code_norm, city_norm,
    net_salary_norm, co_borrower_norm, co_net_salary_norm,
    comments_norm, annexes_norm, annexes_private_norm,
    source_enum_norm, 'PHONING'::stage_enum
  from dedup;

  get diagnostics inserted_count = row_count;
  return query select v_batch_id, inserted_count;
end
$function$;


------------------------------------------------------------
-- 2) import_prospects_from_staging (v2 avec p_is_public)
--    co_borrower → has_co_borrower
------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.import_prospects_from_staging(
  p_batch_label text DEFAULT NULL::text,
  p_obtained_on date DEFAULT CURRENT_DATE,
  p_source source_enum DEFAULT NULL::source_enum,
  p_is_public boolean DEFAULT true
)
RETURNS TABLE(list_batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_batch_id bigint;
BEGIN
  INSERT INTO public.list_batches(
    label, obtained_on, source, size_hint, is_public, created_by
  )
  VALUES (
    COALESCE(NULLIF(p_batch_label,''), 'IMPORT_'||TO_CHAR(NOW(),'YYYYMMDD-HH24MISS')),
    p_obtained_on,
    p_source,
    (SELECT COUNT(*) FROM public.staging_raw_prospects),
    COALESCE(p_is_public, true),
    auth.uid()
  )
  RETURNING id INTO v_batch_id;

  INSERT INTO public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  SELECT
    v_batch_id,
    s.first_name, s.last_name,
    public.normalize_civility(s.civility),
    s.address1, s.address2, s.postal_code, s.city,
    NULLIF(LOWER(TRIM(s.email)), ''),
    public.normalize_fr_phone(s.phone),
    NULLIF(REPLACE(REGEXP_REPLACE(COALESCE(s.net_salary,''),'[^0-9.,\\-]','','g'),',','.'),'')::numeric,
    CASE
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    NULLIF(REPLACE(REGEXP_REPLACE(COALESCE(s.co_net_salary,''),'[^0-9.,\\-]','','g'),',','.'),'')::numeric,
    s.comments,
    s.annexes,
    COALESCE(
      CASE
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('0','false','f','no','n','non') THEN false
        ELSE null
      END, false
    ),
    CASE
      WHEN s.employment_status IN ('FONCTIONNAIRE','INDEPENDANT','SALA_PRIVE','RETRAITE')
        THEN s.employment_status::public.employment_status_enum
      ELSE null
    END,
    CASE
      WHEN s.housing_status IN ('LOCATAIRE','PROPRIETAIRE','HEBERGE')
        THEN s.housing_status::public.housing_status_enum
      ELSE null
    END,
    (
      CASE
        WHEN LEFT(REGEXP_REPLACE(COALESCE(s.postal_code,''),'[^0-9]','','g'),2)
             IN ('75','77','78','91','92','93','94','95') THEN 'IDF'
        WHEN LENGTH(LEFT(REGEXP_REPLACE(COALESCE(s.postal_code,''),'[^0-9]','','g'),2)) = 2 THEN 'PROVINCE'
        ELSE null
      END
    )::public.geo_zone_enum
  FROM public.staging_raw_prospects s;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN QUERY SELECT v_batch_id, inserted_count;
END;
$function$;


------------------------------------------------------------
-- 3) staging_promote_batch (v1 sans p_is_public)
--    co_borrower → has_co_borrower
------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staging_promote_batch(
  p_batch_label text
)
RETURNS TABLE(batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_batch_id bigint;
  v_cnt int;
BEGIN
  INSERT INTO public.list_batches(label)
  VALUES (p_batch_label)
  RETURNING id INTO v_batch_id;

  INSERT INTO public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  SELECT
    v_batch_id,
    s.first_name, s.last_name,
    public.normalize_civility(s.civility),
    s.address1, s.address2, s.postal_code, s.city,
    nullif(lower(trim(s.email)), ''),
    public.normalize_fr_phone(s.phone),
    nullif(replace(regexp_replace(coalesce(s.net_salary,''),'[^0-9.,\\-]','','g'),',','.'),'')::numeric,
    CASE
      WHEN lower(coalesce(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN lower(coalesce(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    nullif(replace(regexp_replace(coalesce(s.co_net_salary,''),'[^0-9.,\\-]','','g'),',','.'),'')::numeric,
    s.comments,
    s.annexes,
    coalesce(
      CASE
        WHEN lower(coalesce(s.annexes_private,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
        WHEN lower(coalesce(s.annexes_private,'')) IN ('0','false','f','no','n','non') THEN false
        ELSE null
      END, false
    ),
    CASE
      WHEN s.employment_status IN ('FONCTIONNAIRE','INDEPENDANT','SALA_PRIVE','RETRAITE')
        THEN s.employment_status::public.employment_status_enum
      ELSE null
    END,
    CASE
      WHEN s.housing_status IN ('LOCATAIRE','PROPRIETAIRE','HEBERGE')
        THEN s.housing_status::public.housing_status_enum
      ELSE null
    END,
    (
      CASE
        WHEN left(regexp_replace(coalesce(s.postal_code,''),'[^0-9]','','g'),2)
             IN ('75','77','78','91','92','93','94','95') THEN 'IDF'
        WHEN length(left(regexp_replace(coalesce(s.postal_code,''),'[^0-9]','','g'),2)) = 2 THEN 'PROVINCE'
        WHEN gl.bucket IS NOT NULL THEN gl.bucket::text
        ELSE null
      END
    )::public.geo_zone_enum
  FROM public.staging_raw_prospects s
  LEFT JOIN LATERAL (
    SELECT g.bucket
    FROM public.geo_city_index g
    WHERE g.city_norm = s.city_norm
      AND (s.postal_code IS NULL OR g.postal_code = s.postal_code)
    ORDER BY (g.postal_code = s.postal_code) DESC NULLS LAST
    LIMIT 1
  ) gl ON true
  WHERE s.batch_label = p_batch_label;

  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  RETURN QUERY SELECT v_batch_id, v_cnt;
END
$function$;


------------------------------------------------------------
-- 4) staging_promote_batch (v2 avec p_is_public)
--    co_borrower → has_co_borrower
------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staging_promote_batch(
  p_batch_label text,
  p_is_public boolean DEFAULT true
)
RETURNS TABLE(batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_batch_id bigint;
  v_cnt int;
BEGIN
  INSERT INTO public.list_batches(label, is_public, created_by)
  VALUES (p_batch_label, COALESCE(p_is_public, true), auth.uid())
  RETURNING id INTO v_batch_id;

  INSERT INTO public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  SELECT
    v_batch_id,
    s.first_name, s.last_name,
    public.normalize_civility(s.civility),
    s.address1, s.address2, s.postal_code, s.city,
    NULLIF(LOWER(TRIM(s.email)), ''),
    public.normalize_fr_phone(s.phone),
    NULLIF(REPLACE(REGEXP_REPLACE(COALESCE(s.net_salary,''),'[^0-9.,\\-]','','g'),',','.'),'')::numeric,
    CASE
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    NULLIF(REPLACE(REGEXP_REPLACE(COALESCE(s.co_net_salary,''),'[^0-9.,\\-]','','g'),',','.'),'')::numeric,
    s.comments,
    s.annexes,
    COALESCE(
      CASE
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('0','false','f','no','n','non') THEN false
        ELSE null
      END, false
    ),
    CASE
      WHEN s.employment_status IN ('FONCTIONNAIRE','INDEPENDANT','SALA_PRIVE','RETRAITE')
        THEN s.employment_status::public.employment_status_enum
      ELSE null
    END,
    CASE
      WHEN s.housing_status IN ('LOCATAIRE','PROPRIETAIRE','HEBERGE')
        THEN s.housing_status::public.housing_status_enum
      ELSE null
    END,
    (
      CASE
        WHEN LEFT(REGEXP_REPLACE(COALESCE(s.postal_code,''),'[^0-9]','','g'),2)
             IN ('75','77','78','91','92','93','94','95') THEN 'IDF'
        WHEN LENGTH(LEFT(REGEXP_REPLACE(COALESCE(s.postal_code,''),'[^0-9]','','g'),2)) = 2 THEN 'PROVINCE'
        ELSE null
      END
    )::public.geo_zone_enum
  FROM public.staging_raw_prospects s
  WHERE s.batch_label = p_batch_label;

  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  RETURN QUERY SELECT v_batch_id, v_cnt;
END;
$function$;


------------------------------------------------------------
-- 5) campaign_create_from_filters
--    p.co_borrower → p.has_co_borrower
------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.campaign_create_from_filters(
  p_name text,
  p_batch_ids bigint[],
  p_geo text,
  p_min_salary numeric,
  p_max_salary numeric,
  p_require_email boolean,
  p_require_coborrower boolean,
  p_phoning_status text[],
  p_employment employment_status_enum[],
  p_housing housing_status_enum[],
  p_member_ids uuid[],
  p_include_employment_null boolean DEFAULT false,
  p_include_housing_null boolean DEFAULT false
)
RETURNS TABLE(campaign_id bigint, created_targets integer, created_members integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

  -- phoning preprocess (comparaison en text)
  if p_phoning_status is not null then
    v_want_phone_null := array_position(p_phoning_status, '__NULL__') is not null;
    v_phone_text := array_remove(p_phoning_status, '__NULL__');
  end if;

  -- 1) campagne
  insert into public.campaigns(name, status, created_by)
  values (p_name, 'INACTIVE', v_uid)
  returning id into v_campaign_id;

  -- 2) membres (ceux fournis)
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
        or (p_require_coborrower = true  and coalesce(p.has_co_borrower,false) = true)
        or (p_require_coborrower = false and coalesce(p.has_co_borrower,false) = false)
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
      and p.owner_id is null
  ),
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
    select b.prospect_id, b.owner_id as chosen
    from base b
    where b.owner_id is not null

    union all

    select n.prospect_id,
           case when v_member_count > 0
                then (select m.m_id from members m
                      where m.ord = ((n.rn - 1) % v_member_count) + 1)
                else null::uuid
           end as chosen
    from numbered n
  )
  , up_owner as (
    update public.prospects p
       set owner_id = d.chosen
    from dispatch d
    where p.id = d.prospect_id
      and p.owner_id is null
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
  insert into public.campaign_members(campaign_id, user_id)
  select distinct v_campaign_id, p.owner_id
  from public.prospects p
  join public.campaign_targets ct on ct.prospect_id = p.id
  where ct.campaign_id = v_campaign_id
    and p.owner_id is not null
  on conflict do nothing;

  update public.campaign_targets ct
     set assigned_to = p.owner_id
  from public.prospects p
  where ct.campaign_id = v_campaign_id
    and ct.prospect_id = p.id
    and (ct.assigned_to is distinct from p.owner_id);

  get diagnostics v_created_targets = row_count;

  return query select v_campaign_id, v_created_targets, v_created_members;
end
$function$;

COMMIT;