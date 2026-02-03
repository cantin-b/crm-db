-- Add email subject logging for UI "Suivi" (emails list)
-- Safe: nullable, no FK, keeps existing KPI logic intact.

ALTER TABLE public.email_events
  ADD COLUMN IF NOT EXISTS subject text;

COMMENT ON COLUMN public.email_events.subject IS 'Email subject as sent (for followup UI / audit).';

-- Optional but useful for sorting/filtering per prospect in UI
CREATE INDEX IF NOT EXISTS idx_email_events_prospect_sent_at
  ON public.email_events (prospect_id, sent_at DESC);