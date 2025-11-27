-- ============================================================
-- MIGRATION : prise en compte de birth_date à l'import
-- Fonctions modifiées :
--   - import_prospects_from_staging(text, date, source_enum, boolean)
--   - staging_promote_batch(text)
--   - staging_promote_batch(text, boolean)
-- Prérequis :
--   - public.staging_raw_prospects.birth_date (text ou équivalent)
--   - public.parse_birth_date(text) RETURNS date
-- ============================================================

-- 1) S'assurer que la colonne existe dans staging_raw_prospects
ALTER TABLE public.staging_raw_prospects
  ADD COLUMN IF NOT EXISTS birth_date text;

-- ============================================================
-- 2) import_prospects_from_staging(p_batch_label, p_obtained_on, p_source, p_is_public)
--    → ajoute birth_date via public.parse_birth_date(s.birth_date)
-- ============================================================
CREATE OR REPLACE FUNCTION public.import_prospects_from_staging(
  p_batch_label text DEFAULT NULL::text,
  p_obtained_on date DEFAULT CURRENT_DATE,
  p_source      source_enum DEFAULT NULL::source_enum,
  p_is_public   boolean DEFAULT true
)
RETURNS TABLE(list_batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_batch_id bigint;
BEGIN
  -- Crée le list_batch
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

  -- Import direct depuis staging_raw_prospects,
  -- en normalisant quelques champs + birth_date
  INSERT INTO public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    birth_date,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  SELECT
    v_batch_id,
    s.first_name,
    s.last_name,
    public.normalize_civility(s.civility),
    public.parse_birth_date(s.birth_date),
    s.address1,
    s.address2,
    s.postal_code,
    s.city,
    NULLIF(LOWER(TRIM(s.email)), ''),
    public.normalize_fr_phone(s.phone),
    NULLIF(
      REPLACE(REGEXP_REPLACE(COALESCE(s.net_salary,''),'[^0-9.,\\-]','','g'),',','.'),
      ''
    )::numeric,
    CASE
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    NULLIF(
      REPLACE(REGEXP_REPLACE(COALESCE(s.co_net_salary,''),'[^0-9.,\\-]','','g'),',','.'),
      ''
    )::numeric,
    s.comments,
    s.annexes,
    COALESCE(
      CASE
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('0','false','f','no','n','non') THEN false
        ELSE null
      END,
      false
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

-- ============================================================
-- 3) staging_promote_batch(p_batch_label, p_is_public)
--    → ajoute birth_date via public.parse_birth_date(s.birth_date)
-- ============================================================
CREATE OR REPLACE FUNCTION public.staging_promote_batch(
  p_batch_label text,
  p_is_public   boolean DEFAULT true
)
RETURNS TABLE(batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_batch_id bigint;
  v_cnt      int;
BEGIN
  INSERT INTO public.list_batches(label, is_public, created_by)
  VALUES (p_batch_label, COALESCE(p_is_public, true), auth.uid())
  RETURNING id INTO v_batch_id;

  INSERT INTO public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    birth_date,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  SELECT
    v_batch_id,
    s.first_name,
    s.last_name,
    public.normalize_civility(s.civility),
    public.parse_birth_date(s.birth_date),
    s.address1,
    s.address2,
    s.postal_code,
    s.city,
    NULLIF(LOWER(TRIM(s.email)), ''),
    public.normalize_fr_phone(s.phone),
    NULLIF(
      REPLACE(REGEXP_REPLACE(COALESCE(s.net_salary,''),'[^0-9.,\\-]','','g'),',','.'),
      ''
    )::numeric,
    CASE
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN LOWER(COALESCE(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    NULLIF(
      REPLACE(REGEXP_REPLACE(COALESCE(s.co_net_salary,''),'[^0-9.,\\-]','','g'),',','.'),
      ''
    )::numeric,
    s.comments,
    s.annexes,
    COALESCE(
      CASE
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
        WHEN LOWER(COALESCE(s.annexes_private,'')) IN ('0','false','f','no','n','non') THEN false
        ELSE null
      END,
      false
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

-- ============================================================
-- 4) staging_promote_batch(p_batch_label)
--    → idem, mais avec la logique geo_city_index existante
--       + ajout de birth_date
-- ============================================================
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
  v_cnt      int;
BEGIN
  INSERT INTO public.list_batches(label)
  VALUES (p_batch_label)
  RETURNING id INTO v_batch_id;

  INSERT INTO public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    birth_date,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  SELECT
    v_batch_id,
    s.first_name,
    s.last_name,
    public.normalize_civility(s.civility),
    public.parse_birth_date(s.birth_date),
    s.address1,
    s.address2,
    s.postal_code,
    s.city,
    NULLIF(LOWER(TRIM(s.email)), ''),
    public.normalize_fr_phone(s.phone),
    NULLIF(
      REPLACE(REGEXP_REPLACE(COALESCE(s.net_salary,''),'[^0-9.,\\-]','','g'),',','.'),
      ''
    )::numeric,
    CASE
      WHEN lower(coalesce(s.co_borrower,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
      WHEN lower(coalesce(s.co_borrower,'')) IN ('0','false','f','no','n','non') THEN false
      ELSE null
    END,
    NULLIF(
      REPLACE(REGEXP_REPLACE(COALESCE(s.co_net_salary,''),'[^0-9.,\\-]','','g'),',','.'),
      ''
    )::numeric,
    s.comments,
    s.annexes,
    COALESCE(
      CASE
        WHEN lower(coalesce(s.annexes_private,'')) IN ('1','true','t','yes','y','oui','vrai','x') THEN true
        WHEN lower(coalesce(s.annexes_private,'')) IN ('0','false','f','no','n','non') THEN false
        ELSE null
      END,
      false
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
END;
$function$;

-- ============================================================
-- (OPTIONNEL) 5) Backfill des prospects déjà importés
--    ⚠️ Ne fonctionnera que si les lignes d'origine sont encore
--       présentes dans staging_raw_prospects avec un batch_label cohérent.
--    Tu peux décommenter ce bloc si besoin :
-- ============================================================
/*
UPDATE public.prospects p
SET birth_date = public.parse_birth_date(s.birth_date)
FROM public.staging_raw_prospects s
WHERE p.list_batch_id = (
  SELECT id FROM public.list_batches b
  WHERE b.label = s.batch_label
  LIMIT 1
)
AND p.birth_date IS NULL
AND s.birth_date IS NOT NULL
AND p.first_name = s.first_name
AND p.last_name  = s.last_name;
*/