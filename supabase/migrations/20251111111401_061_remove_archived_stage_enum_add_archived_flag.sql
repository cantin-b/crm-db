-- 1) Nouveau type d'étape SANS ARCHIVED
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t WHERE t.typname = 'stage_enum_v2'
  ) THEN
    CREATE TYPE stage_enum_v2 AS ENUM ('PHONING','OPPORTUNITY','VALIDATION','CONTRACT');
  END IF;
END$$;

-- 2) Ajouter le booléen archived (par défaut false)
ALTER TABLE public.prospects
  ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false;

-- 3) Migrer la colonne prospects.stage vers le nouveau type
ALTER TABLE public.prospects
  ALTER COLUMN stage DROP DEFAULT;

ALTER TABLE public.prospects
  ALTER COLUMN stage TYPE stage_enum_v2
  USING (
    CASE
      WHEN stage::text = 'ARCHIVED' THEN 'CONTRACT'::stage_enum_v2
      ELSE stage::text::stage_enum_v2
    END
  );

-- 4) Migrer l’historique (from_stage / to_stage)
ALTER TABLE public.prospect_stage_history
  ALTER COLUMN from_stage TYPE stage_enum_v2
  USING (
    CASE
      WHEN from_stage::text = 'ARCHIVED' THEN 'CONTRACT'::stage_enum_v2
      ELSE from_stage::text::stage_enum_v2
    END
  );

ALTER TABLE public.prospect_stage_history
  ALTER COLUMN to_stage TYPE stage_enum_v2
  USING (
    CASE
      WHEN to_stage::text = 'ARCHIVED' THEN 'CONTRACT'::stage_enum_v2
      ELSE to_stage::text::stage_enum_v2
    END
  );

-- 5) Remettre le DEFAULT
ALTER TABLE public.prospects
  ALTER COLUMN stage SET DEFAULT 'PHONING'::stage_enum_v2;

-- 6) Poser archived=true pour les dossiers qui étaient ARCHIVED
UPDATE public.prospects
SET archived = true,
    archived_at = COALESCE(archived_at, now())
WHERE archived = false AND stage = 'CONTRACT'
  AND id IN (
    SELECT p.id
    FROM public.prospects p
    JOIN public.prospect_stage_history h ON h.prospect_id = p.id
    -- heuristique : dernier to_stage = ARCHIVED avant migration
    WHERE h.changed_at = (
      SELECT MAX(changed_at) FROM public.prospect_stage_history h2 WHERE h2.prospect_id = p.id
    )
    AND h.to_stage::text = 'CONTRACT'  -- après l'étape 3, l’ancien ARCHIVED a été retypé en CONTRACT
  );

-- 7) (optionnel) Renommer le type proprement et supprimer l’ancien
DO $$
BEGIN
  -- renommer l'ancien stage_enum -> stage_enum_old si présent
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'stage_enum') THEN
    ALTER TYPE stage_enum RENAME TO stage_enum_old;
  END IF;

  -- renommer stage_enum_v2 -> stage_enum
  ALTER TYPE stage_enum_v2 RENAME TO stage_enum;

  -- essayer de drop l’ancien si plus aucune colonne ne l’utilise
  BEGIN
    DROP TYPE stage_enum_old;
  EXCEPTION WHEN undefined_object THEN
    -- déjà supprimé / inexistant : ignorer
    NULL;
  END;
END$$;
