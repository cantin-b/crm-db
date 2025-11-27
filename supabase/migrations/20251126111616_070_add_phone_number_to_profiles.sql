BEGIN;

ALTER TABLE public.profiles
  ADD COLUMN phone_e164 text
  CHECK (
    phone_e164 IS NULL
    OR phone_e164 ~ '^\+33\d{9}$'
  );

COMMIT;