-- 1) prospects: flag délégation
ALTER TABLE public.prospects
  ADD COLUMN IF NOT EXISTS has_delegation boolean;

-- 2) documents: transformer en "exigences" (requis/statut/libellé)
ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS label text,
  ADD COLUMN IF NOT EXISTS kind text,
  ADD COLUMN IF NOT EXISTS is_custom boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS required boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS status docs_status_enum;

-- 3) historique de mails par document (pivot)
CREATE TABLE IF NOT EXISTS public.email_event_documents (
  email_event_id bigint NOT NULL REFERENCES public.email_events(id) ON DELETE CASCADE,
  document_id    bigint NOT NULL REFERENCES public.documents(id) ON DELETE CASCADE,
  PRIMARY KEY (email_event_id, document_id)
);

-- 4) index utiles
CREATE INDEX IF NOT EXISTS idx_documents_prospect ON public.documents(prospect_id);
CREATE INDEX IF NOT EXISTS idx_documents_kind ON public.documents(kind);
CREATE INDEX IF NOT EXISTS idx_documents_required ON public.documents(required);

-- 5) contraintes de cohérence (douces : on évite les erreurs si déjà présentes)
DO $$
BEGIN
  -- unicité logique: un "kind" par prospect (hors custom)
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uniq_documents_prospect_kind_non_custom'
  ) THEN
    ALTER TABLE public.documents
      ADD CONSTRAINT uniq_documents_prospect_kind_non_custom
      UNIQUE (prospect_id, kind)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;

  -- optionnel: éviter doublons de libellé custom par prospect
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uniq_documents_prospect_label_custom'
  ) THEN
    ALTER TABLE public.documents
      ADD CONSTRAINT uniq_documents_prospect_label_custom
      UNIQUE (prospect_id, label, is_custom)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END$$;

-- 6) check: status seulement si required
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_documents_required_status'
  ) THEN
    ALTER TABLE public.documents
      ADD CONSTRAINT chk_documents_required_status
      CHECK (
        (required = false AND status IS NULL)
        OR
        (required = true  AND status IS NOT NULL)
      );
  END IF;
END$$;