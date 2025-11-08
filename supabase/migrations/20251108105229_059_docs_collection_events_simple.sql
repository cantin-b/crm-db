-- 0) Enum : crée si absent
DO $$ BEGIN
  CREATE TYPE public.docs_collection_event_type AS ENUM ('INITIAL_REQUEST','REMINDER_SENT');
EXCEPTION WHEN duplicate_object THEN
  -- Si elle existe déjà, rien à faire
  NULL;
END $$;

-- 1) Table d'historique (niveau PROSPECT, pas par document)
CREATE TABLE IF NOT EXISTS public.docs_collection_events (
  id           bigserial PRIMARY KEY,
  prospect_id  uuid NOT NULL REFERENCES public.prospects(id) ON DELETE CASCADE,
  event_type   public.docs_collection_event_type NOT NULL,
  event_at     timestamptz NOT NULL DEFAULT now(),
  user_id      uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  -- Optionnel: traces du mail
  email_subject text,
  email_html    text
);

-- 2) Index usuels
CREATE INDEX IF NOT EXISTS idx_docs_coll_events_prospect
  ON public.docs_collection_events(prospect_id, event_at DESC);

CREATE INDEX IF NOT EXISTS idx_docs_coll_events_type
  ON public.docs_collection_events(event_type, event_at DESC);

-- 3) Vue pratique pour l’UI (dates & compteur par prospect)
CREATE OR REPLACE VIEW public.v_docs_collection_stats AS
SELECT
  p.id AS prospect_id,
  MIN(CASE WHEN e.event_type = 'INITIAL_REQUEST' THEN e.event_at END) AS first_request_at,
  MAX(CASE WHEN e.event_type = 'REMINDER_SENT'  THEN e.event_at END) AS last_reminder_at,
  COUNT(*) FILTER (WHERE e.event_type = 'REMINDER_SENT')              AS reminder_count
FROM public.prospects p
LEFT JOIN public.docs_collection_events e
  ON e.prospect_id = p.id
GROUP BY p.id;