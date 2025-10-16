-- 044_add_is_public_to_list_batches.sql
-- Ajout d’un flag is_public sur list_batches + RLS + patch fonctions

BEGIN;

-- 1) Nouvelle colonne
ALTER TABLE public.list_batches
  ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT true;

-- 2) Index de filtrage
CREATE INDEX IF NOT EXISTS list_batches_is_public_idx
  ON public.list_batches (is_public);

-- 3) RLS : activer si pas déjà
ALTER TABLE public.list_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prospects ENABLE ROW LEVEL SECURITY;

-- 4) Policies list_batches
DROP POLICY IF EXISTS list_batches_select_all ON public.list_batches;
CREATE POLICY list_batches_select
  ON public.list_batches
  FOR SELECT
  USING (
    public.is_admin()
    OR (is_public = true)
  );

DROP POLICY IF EXISTS list_batches_ins ON public.list_batches;
CREATE POLICY list_batches_insert
  ON public.list_batches
  FOR INSERT
  WITH CHECK (
    public.is_admin()
    OR (is_public = true)
  );

DROP POLICY IF EXISTS list_batches_update ON public.list_batches;
CREATE POLICY list_batches_update
  ON public.list_batches
  FOR UPDATE
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- 5) Policies prospects : cacher ceux issus de lots privés aux non-admin
DROP POLICY IF EXISTS prospects_select ON public.prospects;
CREATE POLICY prospects_select_visible_batches
  ON public.prospects
  FOR SELECT
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.list_batches b
      WHERE b.id = public.prospects.list_batch_id
        AND b.is_public = true
    )
  );

DROP POLICY IF EXISTS prospects_insert ON public.prospects;
CREATE POLICY prospects_insert
  ON public.prospects
  FOR INSERT
  WITH CHECK (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.list_batches b
      WHERE b.id = list_batch_id AND b.is_public = true
    )
  );

DROP POLICY IF EXISTS prospects_update ON public.prospects;
CREATE POLICY prospects_update
  ON public.prospects
  FOR UPDATE
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.list_batches b
      WHERE b.id = list_batch_id AND b.is_public = true
    )
  )
  WITH CHECK (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.list_batches b
      WHERE b.id = list_batch_id AND b.is_public = true
    )
  );

-- 6) Patch fonctions pour supporter le flag p_is_public

CREATE OR REPLACE FUNCTION public.ensure_list_batch(
  p_label text,
  p_is_public boolean default true
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  bid bigint;
BEGIN
  SELECT id INTO bid FROM public.list_batches WHERE label = p_label LIMIT 1;
  IF bid IS NULL THEN
    INSERT INTO public.list_batches(label, obtained_on, is_public, created_by)
    VALUES (p_label, now()::date, COALESCE(p_is_public, true), auth.uid())
    RETURNING id INTO bid;
  END IF;
  RETURN bid;
END;
$$;

CREATE OR REPLACE FUNCTION public.staging_promote_batch(
  p_batch_label text,
  p_is_public boolean default true
)
RETURNS TABLE(batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_batch_id bigint;
  v_cnt int;
BEGIN
  INSERT INTO public.list_batches(label, is_public, created_by)
  VALUES (p_batch_label, COALESCE(p_is_public, true), auth.uid())
  RETURNING id INTO v_batch_id;

  -- corps original conservé (imports staging)
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
$$;

CREATE OR REPLACE FUNCTION public.import_prospects_from_staging(
  p_batch_label text default null,
  p_obtained_on date default current_date,
  p_source public.source_enum default null,
  p_is_public boolean default true
)
RETURNS TABLE(list_batch_id bigint, inserted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE v_batch_id bigint;
BEGIN
  INSERT INTO public.list_batches(label, obtained_on, source, size_hint, is_public, created_by)
  VALUES (
    COALESCE(NULLIF(p_batch_label,''), 'IMPORT_'||TO_CHAR(NOW(),'YYYYMMDD-HH24MISS')),
    p_obtained_on,
    p_source,
    (SELECT COUNT(*) FROM public.staging_raw_prospects),
    COALESCE(p_is_public, true),
    auth.uid()
  )
  RETURNING id INTO v_batch_id;

  -- corps original conservé (insert prospects)
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
$$;

COMMIT;
