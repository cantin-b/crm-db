-- 042_recreate_prospects_phone_trigger.sql
-- Objectif : s'assurer que la normalisation téléphone s'applique
-- aussi aux écritures directes sur public.prospects (INSERT/UPDATE).

BEGIN;

-- 1) (Re)créer le trigger seulement s'il n'existe pas
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'tgn_prospects_normalize_phone'
  ) THEN
    CREATE TRIGGER tgn_prospects_normalize_phone
      BEFORE INSERT OR UPDATE OF phone_e164 ON public.prospects
      FOR EACH ROW
      EXECUTE FUNCTION public.trg_prospects_normalize_phone();
  END IF;
END$$;

-- 2) Normalisation idempotente des données existantes (devrait être no-op)
UPDATE public.prospects
   SET phone_e164 = public.normalize_fr_phone(phone_e164)
 WHERE phone_e164 IS NOT NULL
   AND phone_e164 !~ '^\+33\d{9}$';

COMMIT;
