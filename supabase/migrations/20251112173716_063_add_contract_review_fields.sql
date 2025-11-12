
DO $$
BEGIN
  -- Booléen: la demande initiale d'avis Google a été envoyée
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_requested'
  ) THEN
    ALTER TABLE public.prospects
      ADD COLUMN contract_review_requested boolean NOT NULL DEFAULT false;
  END IF;

  -- Compteur: nombre de relances après la demande initiale
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_followup_count'
  ) THEN
    ALTER TABLE public.prospects
      ADD COLUMN contract_review_followup_count integer NOT NULL DEFAULT 0
      CHECK (contract_review_followup_count >= 0);
  END IF;

  -- (Optionnel mais utile) Horodatages pour audit/UX
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_requested_at'
  ) THEN
    ALTER TABLE public.prospects
      ADD COLUMN contract_review_requested_at timestamptz;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_last_followup_at'
  ) THEN
    ALTER TABLE public.prospects
      ADD COLUMN contract_review_last_followup_at timestamptz;
  END IF;

  -- (Optionnel) petit index composite pratique pour filtrer les contrats à relancer
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname  = 'idx_prospects_contract_review_stage'
  ) THEN
    CREATE INDEX idx_prospects_contract_review_stage
      ON public.prospects (stage, contract_review_requested);
  END IF;
END $$;

-- ========================
-- DOWN
-- ========================
DO $$
BEGIN
  -- Supprime l'index si présent
  IF EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname  = 'idx_prospects_contract_review_stage'
  ) THEN
    DROP INDEX public.idx_prospects_contract_review_stage;
  END IF;

  -- Supprime les colonnes (ordre inverse par sécurité)
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_last_followup_at'
  ) THEN
    ALTER TABLE public.prospects
      DROP COLUMN contract_review_last_followup_at;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_requested_at'
  ) THEN
    ALTER TABLE public.prospects
      DROP COLUMN contract_review_requested_at;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_followup_count'
  ) THEN
    ALTER TABLE public.prospects
      DROP COLUMN contract_review_followup_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'prospects'
      AND column_name  = 'contract_review_requested'
  ) THEN
    ALTER TABLE public.prospects
      DROP COLUMN contract_review_requested;
  END IF;
END $$;
