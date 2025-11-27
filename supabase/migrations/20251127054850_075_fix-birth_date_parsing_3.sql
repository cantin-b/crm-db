-- 01_fix_staging_birth_date_and_parse_function.sql
BEGIN;

-- 1) S'assurer que staging_raw_prospects.birth_date est bien du texte
--    (pour ne plus subir les histoires de timezone lors de l'import)
ALTER TABLE public.staging_raw_prospects
  ALTER COLUMN birth_date TYPE text
  USING birth_date::text;

-- 2) Rendre parse_birth_date robuste aux timestamps/timestamptz
--    et toujours parser uniquement la partie date.
CREATE OR REPLACE FUNCTION public.parse_birth_date(s text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  t    text;
  d    date;
  core text;
BEGIN
  IF s IS NULL OR length(trim(s)) = 0 THEN
    RETURN NULL;
  END IF;

  t := trim(s);

  ------------------------------------------------------------------
  -- Cas 0 : on a un truc du genre '1991-12-30 00:00:00+01'
  --         → on extrait juste la partie '1991-12-30'
  ------------------------------------------------------------------
  core := substring(t from '(\d{4}-\d{2}-\d{2})');
  IF core IS NOT NULL THEN
    BEGIN
      d := to_date(core, 'YYYY-MM-DD');
      RETURN d;
    EXCEPTION WHEN others THEN
      -- on continue sur les formats suivants
      NULL;
    END;
  END IF;

  ------------------------------------------------------------------
  -- Cas 1 : formats YYYY-MM-DD ou YYYY/MM/DD
  ------------------------------------------------------------------
  IF t ~ '^\d{4}[-/]\d{2}[-/]\d{2}$' THEN
    BEGIN
      d := to_date(replace(t, '/', '-'), 'YYYY-MM-DD');
      RETURN d;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
  END IF;

  ------------------------------------------------------------------
  -- Cas 2 : formats DD-MM-YYYY ou DD/MM/YYYY
  ------------------------------------------------------------------
  IF t ~ '^\d{2}[-/]\d{2}[-/]\d{4}$' THEN
    BEGIN
      d := to_date(replace(t, '/', '-'), 'DD-MM-YYYY');
      RETURN d;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
  END IF;

  ------------------------------------------------------------------
  -- Cas 3 : formats '12 07 1985'
  ------------------------------------------------------------------
  IF t ~ '^\d{1,2} \d{1,2} \d{4}$' THEN
    BEGIN
      d := to_date(t, 'DD MM YYYY');
      RETURN d;
    EXCEPTION WHEN others THEN
      RETURN NULL;
    END;
  END IF;

  ------------------------------------------------------------------
  -- Cas 4 : dernier recours
  --         on cast la première "token" avant l'espace en date
  --         (évite que le timestamptz complet subisse le décalage)
  ------------------------------------------------------------------
  BEGIN
    d := split_part(t, ' ', 1)::date;
    RETURN d;
  EXCEPTION WHEN others THEN
    RETURN NULL;
  END;
END;
$function$;

COMMIT;