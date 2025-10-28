ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS smtp_pssd text;