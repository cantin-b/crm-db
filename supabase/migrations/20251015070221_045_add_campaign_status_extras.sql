-- 045_add_campaign_status_extras.sql
-- Ajoute PAUSED + timestamps statut + triggers d’audit et verrous sur campaigns
-- ⚙️  Compatible avec les fonctions existantes (aucune rupture)

BEGIN;

-- 1) Enum : ajout de la valeur PAUSED si absente
ALTER TYPE public.campaign_status_enum ADD VALUE IF NOT EXISTS 'PAUSED';

-- 2) Colonnes d’horodatage (créées si absentes)
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS status_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS activated_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- 3) Fonction trigger : audit des statuts
CREATE OR REPLACE FUNCTION public.trg_campaigns_status_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status_changed_at IS NULL THEN
      NEW.status_changed_at := now();
    END IF;

    IF NEW.status = 'ACTIVE' AND NEW.activated_at IS NULL THEN
      NEW.activated_at := now();
    END IF;

    IF NEW.status = 'ARCHIVED' AND NEW.archived_at IS NULL THEN
      NEW.archived_at := now();
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_changed_at := now();

    IF NEW.status = 'ACTIVE' AND NEW.activated_at IS NULL THEN
      NEW.activated_at := now();
    END IF;

    IF NEW.status = 'ARCHIVED' AND NEW.archived_at IS NULL THEN
      NEW.archived_at := now();
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- 4) Fonction trigger : verrouillage des campagnes archivées
CREATE OR REPLACE FUNCTION public.trg_campaigns_lock_when_archived()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_admin_or_service boolean;
BEGIN
  v_is_admin_or_service := COALESCE(public._is_admin_or_service(), false);

  IF OLD.status = 'ARCHIVED' AND NOT v_is_admin_or_service THEN
    IF (NEW.* IS DISTINCT FROM OLD.*) THEN
      RAISE EXCEPTION 'Cette campagne est archivée et ne peut plus être modifiée.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF OLD.status = 'ARCHIVED' AND NEW.status IS DISTINCT FROM OLD.status AND NOT v_is_admin_or_service THEN
    RAISE EXCEPTION 'Impossible de désarchiver une campagne (% -> %).', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- 5) Déclencheurs idempotents
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_campaigns_status_audit_biu') THEN
    DROP TRIGGER trg_campaigns_status_audit_biu ON public.campaigns;
  END IF;
END$$;

CREATE TRIGGER trg_campaigns_status_audit_biu
BEFORE INSERT OR UPDATE ON public.campaigns
FOR EACH ROW
EXECUTE FUNCTION public.trg_campaigns_status_audit();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_campaigns_lock_when_archived_bu') THEN
    DROP TRIGGER trg_campaigns_lock_when_archived_bu ON public.campaigns;
  END IF;
END$$;

CREATE TRIGGER trg_campaigns_lock_when_archived_bu
BEFORE UPDATE ON public.campaigns
FOR EACH ROW
EXECUTE FUNCTION public.trg_campaigns_lock_when_archived();

-- 6) Index pour filtrage rapide par statut
CREATE INDEX IF NOT EXISTS idx_campaigns_status ON public.campaigns(status);

-- 7) Backfill léger (si vide)
UPDATE public.campaigns
   SET activated_at = COALESCE(activated_at, now())
 WHERE status = 'ACTIVE' AND activated_at IS NULL;

UPDATE public.campaigns
   SET archived_at = COALESCE(archived_at, now())
 WHERE status = 'ARCHIVED' AND archived_at IS NULL;

UPDATE public.campaigns
   SET status_changed_at = COALESCE(created_at, now())
 WHERE status_changed_at IS NULL;

COMMIT;
