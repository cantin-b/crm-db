-- ============================================================
--  MIGRATION : Fix birth_date parsing during staging promotion
--  Includes:
--   - parse_birth_date() (idempotent)
--   - import_prospects_from_staging(p_batch_label, p_obtained_on, p_source)
-- ============================================================

-------------------------------
-- 1) CREATE OR REPLACE parse_birth_date
-------------------------------
CREATE OR REPLACE FUNCTION public.parse_birth_date(s text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  t text;
  d date;
BEGIN
  IF s IS NULL OR length(trim(s)) = 0 THEN
    RETURN NULL;
  END IF;

  t := trim(s);

  -- Formats YYYY-MM-DD ou YYYY/MM/DD
  IF t ~ '^\d{4}[-/]\d{2}[-/]\d{2}$' THEN
    BEGIN
      d := to_date(replace(t, '/', '-'), 'YYYY-MM-DD');
      RETURN d;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
  END IF;

  -- Formats DD-MM-YYYY ou DD/MM/YYYY
  IF t ~ '^\d{2}[-/]\d{2}[-/]\d{4}$' THEN
    BEGIN
      d := to_date(replace(t, '/', '-'), 'DD-MM-YYYY');
      RETURN d;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
  END IF;

  -- Formats "12 07 1985" etc.
  IF t ~ '^\d{1,2} \d{1,2} \d{4}$' THEN
    BEGIN
      d := to_date(t, 'DD MM YYYY');
      RETURN d;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
  END IF;

  -- Dernier recours : cast direct
  BEGIN
    d := t::date;
    RETURN d;
  EXCEPTION WHEN others THEN
    RETURN NULL;
  END;

END;
$function$;


-------------------------------
-- 2) CREATE OR REPLACE import_prospects_from_staging (3 params)
-------------------------------
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
DECLARE
  v_batch_id bigint;
BEGIN
  -- Create list batch
  INSERT INTO public.list_batches(label, obtained_on, source, size_hint)
  VALUES (
    COALESCE(NULLIF(p_batch_label,''), 'IMPORT_'||to_char(now(),'YYYYMMDD-HH24MISS')),
    p_obtained_on,
    p_source,
    (SELECT count(*) FROM public.staging_raw_prospects)
  )
  RETURNING id INTO v_batch_id;

  -- Normalize staging rows
  WITH src AS (
    SELECT
      NULLIF(trim(first_name),'')                                AS first_name,
      NULLIF(trim(last_name),'')                                 AS last_name,
      public.normalize_email(email)                              AS email_norm,
      public.normalize_fr_phone(phone)                           AS phone_norm,
      NULLIF(upper(trim(civility)),'')                           AS civility_norm,

      -- IMPORTANT : parse_birth_date here
      public.parse_birth_date(birth_date)                        AS birth_norm,

      NULLIF(trim(address1),'')                                  AS address1_norm,
      NULLIF(trim(address2),'')                                  AS address2_norm,
      public.normalize_cp(postal_code)                           AS postal_code_norm,
      NULLIF(trim(city),'')                                      AS city_norm,
      NULLIF(regexp_replace(net_salary,'[^\\d.,]','','g'),'')::numeric    AS net_salary_norm,
      public.parse_bool(co_borrower)                             AS co_borrower_norm,
      NULLIF(regexp_replace(co_net_salary,'[^\\d.,]','','g'),'')::numeric AS co_net_salary_norm,
      NULLIF(trim(comments),'')                                  AS comments_norm,
      NULLIF(trim(annexes),'')                                   AS annexes_norm,
      COALESCE(public.parse_bool(annexes_private), FALSE)        AS annexes_private_norm,
      CASE upper(trim(source))
        WHEN 'PARRAINAGE'    THEN 'PARRAINAGE'::source_enum
        WHEN 'LEAD'          THEN 'LEAD'::source_enum
        WHEN 'LISTE_ACHETEE' THEN 'LISTE_ACHETEE'::source_enum
        ELSE NULL END                                            AS source_enum_norm
    FROM public.staging_raw_prospects
  ),

  filtered AS (
    SELECT * FROM src
    WHERE first_name IS NOT NULL
      AND last_name  IS NOT NULL
      AND (phone_norm IS NOT NULL OR email_norm IS NOT NULL)
  ),

  dedup AS (
    SELECT f.*
    FROM filtered f
    WHERE NOT EXISTS (
      SELECT 1 FROM public.prospects p
       WHERE (f.phone_norm IS NOT NULL AND p.phone_e164 = f.phone_norm)
          OR (f.email_norm IS NOT NULL AND p.email      = f.email_norm)
    )
  )

  INSERT INTO public.prospects (
    list_batch_id, first_name, last_name, email, phone_e164,
    civility, birth_date,
    address1, address2, postal_code, city,
    net_salary, has_co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    source, stage
  )
  SELECT
    v_batch_id,
    first_name, last_name, email_norm, phone_norm,
    public.normalize_civility(civility_norm),
    birth_norm,
    address1_norm, address2_norm, postal_code_norm, city_norm,
    net_salary_norm, co_borrower_norm, co_net_salary_norm,
    comments_norm, annexes_norm, annexes_private_norm,
    source_enum_norm, 'PHONING'::stage_enum
  FROM dedup;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;

  RETURN QUERY SELECT v_batch_id, inserted_count;
END;
$function$;