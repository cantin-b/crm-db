-- 043_add_civility_enum.sql
-- Enum & migration for standardized civilities (M., Mme, Mlle)

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'civility_enum' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.civility_enum AS ENUM ('M.', 'Mme', 'Mlle');
  END IF;
END$$;

-- Normalizer: map various inputs to the enum (or NULL)
CREATE OR REPLACE FUNCTION public.normalize_civility(s text)
RETURNS public.civility_enum
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  t text;
BEGIN
  IF s IS NULL OR btrim(s) = '' THEN
    RETURN NULL;
  END IF;

  t := lower(regexp_replace(public.unaccent(btrim(s)), '[\.\s_-]+', '', 'g'));

  IF t IN ('m','mr','monsieur','mon','monsr','msieur') THEN
    RETURN 'M.'::public.civility_enum;
  ELSIF t IN ('mme','madame','mad','mm') THEN
    RETURN 'Mme'::public.civility_enum;
  ELSIF t IN ('mlle','ml','melle','mademoiselle','mademoisel','mlles') THEN
    RETURN 'Mlle'::public.civility_enum;
  END IF;

  RETURN NULL;
END$$;

-- Migrate column type (text -> enum) with normalization
ALTER TABLE public.prospects
  ALTER COLUMN civility TYPE public.civility_enum
  USING public.normalize_civility(civility);

-- Explicitly keep NULL default
ALTER TABLE public.prospects
  ALTER COLUMN civility DROP DEFAULT;

-- ✅ Keep staging_promote_batch coherent with the enum
CREATE OR REPLACE FUNCTION public.staging_promote_batch(p_batch_label text)
RETURNS TABLE(batch_id bigint, inserted_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
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
    net_salary, co_borrower, co_net_salary,
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
    nullif(replace(regexp_replace(coalesce(s.net_salary,''),'[^0-9.,\-]','','g'),',','.'),'')::numeric,
    CASE
      WHEN lower(coalesce(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN lower(coalesce(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    nullif(replace(regexp_replace(coalesce(s.co_net_salary,''),'[^0-9.,\-]','','g'),',','.'),'')::numeric,
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
$$;

-- ✅ Patch: align import_prospects_from_staging with civility_enum
CREATE OR REPLACE FUNCTION public.import_prospects_from_staging(
  p_batch_label text DEFAULT NULL::text,
  p_obtained_on date DEFAULT CURRENT_DATE,
  p_source public.source_enum DEFAULT NULL::public.source_enum
)
RETURNS TABLE(list_batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare v_batch_id bigint;
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
    net_salary, co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    source, stage
  )
  select
    v_batch_id,
    first_name, last_name, email_norm, phone_norm,
    public.normalize_civility(civility_norm),   -- 👈 convert to enum (or NULL)
    birth_norm,
    address1_norm, address2_norm, postal_code_norm, city_norm,
    net_salary_norm, co_borrower_norm, co_net_salary_norm,
    comments_norm, annexes_norm, annexes_private_norm,
    source_enum_norm, 'PHONING'::stage_enum
  from dedup;

  get diagnostics inserted_count = row_count;
  return query select v_batch_id, inserted_count;
end
$$;
