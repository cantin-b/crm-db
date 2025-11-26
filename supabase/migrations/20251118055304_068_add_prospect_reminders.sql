-- 20251118_add_prospect_reminders.sql
-- Ajout enum + table des rappels + contrainte d’unicité sur les rappels PLANNED

------------------------------------------------------------
-- 1) Enum : reminder_status_enum
------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'reminder_status_enum'
  ) THEN
    CREATE TYPE public.reminder_status_enum AS ENUM (
      'PLANNED',
      'DONE',
      'CANCELED'
    );
  END IF;
END
$$;

------------------------------------------------------------
-- 2) Table : public.prospect_reminders
------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.prospect_reminders (
  id                BIGSERIAL PRIMARY KEY,

  -- Rappel lié à un prospect
  prospect_id       UUID NOT NULL
                    REFERENCES public.prospects(id)
                    ON DELETE CASCADE,

  -- Jour du rappel (logique métier : fuseau Paris géré côté app)
  reminder_date     DATE NOT NULL,

  -- Note libre : "rappeler fin de matinée", "après signature offre", etc.
  note              TEXT,

  -- Statut du rappel
  status            public.reminder_status_enum NOT NULL DEFAULT 'PLANNED',

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Optionnel : opérateur qui a créé / modifié le rappel
  created_by        UUID REFERENCES public.profiles(id),

  -- Date/heure à laquelle le rappel a été effectivement traité
  completed_at      TIMESTAMPTZ,

  -- Nombre de replanifications du rappel
  reschedule_count  INTEGER NOT NULL DEFAULT 0
);

------------------------------------------------------------
-- 3) Contrainte métier : 1 seul rappel PLANNED par prospect
------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uniq_prospect_reminder_planned
ON public.prospect_reminders (prospect_id)
WHERE status = 'PLANNED';

------------------------------------------------------------
-- 4) Trigger updated_at (réutilise la fonction set_updated_at si elle existe)
------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'set_updated_at'
      AND pg_function_is_visible(oid)
  ) THEN
    -- On garde la même convention de nom de trigger que sur les autres tables
    IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger
      WHERE tgname = 'set_updated_at'
        AND tgrelid = 'public.prospect_reminders'::regclass
    ) THEN
      CREATE TRIGGER set_updated_at
      BEFORE UPDATE ON public.prospect_reminders
      FOR EACH ROW
      EXECUTE FUNCTION public.set_updated_at();
    END IF;
  END IF;
END
$$;