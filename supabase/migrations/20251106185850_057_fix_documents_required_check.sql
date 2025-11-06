-- 1) Supprimer l'ancien CHECK d'abord
ALTER TABLE public.documents
  DROP CONSTRAINT IF EXISTS chk_documents_required_status;

-- 2) Recréer le CHECK compatible avec NOT_REQUIRED
ALTER TABLE public.documents
  ADD CONSTRAINT chk_documents_required_status
  CHECK (
    (required = false AND status = 'NOT_REQUIRED')
    OR
    (required = true  AND status IN ('PENDING','INCOMPLETE','RECEIVED'))
  );

-- 3) Normaliser les données existantes (maintenant que la contrainte le permet)
UPDATE public.documents
SET status = 'NOT_REQUIRED'
WHERE required = false
  AND (status IS NULL OR status <> 'NOT_REQUIRED');

-- (optionnel) interdire les NULL pour uniformiser
-- ALTER TABLE public.documents ALTER COLUMN status SET NOT NULL;