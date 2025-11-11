-- migrate:up

BEGIN;

-- 1) Table du plan de validation (affichage/activation des étapes)
--    NB: on suppose que public.validation_step_enum existe déjà.
CREATE TABLE IF NOT EXISTS public.validation_plan (
  prospect_id uuid NOT NULL
    REFERENCES public.prospects(id) ON DELETE CASCADE,
  step public.validation_step_enum NOT NULL,
  required boolean NOT NULL DEFAULT true,   -- ON/OFF (étape active dans la frise)
  position smallint NOT NULL,               -- ordre d’affichage
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT validation_plan_pkey PRIMARY KEY (prospect_id, step)
);

-- 2) Index pour chargement trié par prospect
CREATE INDEX IF NOT EXISTS validation_plan_prospect_pos_idx
  ON public.validation_plan (prospect_id, position);

-- 3) Trigger updated_at (optionnel) : n’est créé que si la fonction existe déjà
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = 'set_updated_at'
      AND n.nspname = 'public'
  ) THEN
    -- éviter doublon si le trigger existe déjà
    IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger
      WHERE tgrelid = 'public.validation_plan'::regclass
        AND tgname = 'set_updated_at'
    ) THEN
      CREATE TRIGGER set_updated_at
      BEFORE UPDATE ON public.validation_plan
      FOR EACH ROW
      EXECUTE FUNCTION public.set_updated_at();
    END IF;
  END IF;
END $$;

-- 4) (Optionnel) RLS : à activer si vous avez les policies prêtes.
--    Par défaut, désactivé pour éviter de bloquer le front.
-- ALTER TABLE public.validation_plan ENABLE ROW LEVEL SECURITY;

COMMIT;


-- migrate:down
BEGIN;

-- Supprimer trigger si présent
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.validation_plan'::regclass
      AND tgname = 'set_updated_at'
  ) THEN
    DROP TRIGGER set_updated_at ON public.validation_plan;
  END IF;
END $$;

-- Supprimer index
DROP INDEX IF EXISTS public.validation_plan_prospect_pos_idx;

-- Supprimer table
DROP TABLE IF EXISTS public.validation_plan;

COMMIT;