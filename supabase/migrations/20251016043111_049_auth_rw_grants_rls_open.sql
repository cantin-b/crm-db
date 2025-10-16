-- 0) Schéma & séquences (tu as déjà, je laisse ici pour idempotence)
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Appliquer aussi aux futures séquences/tables créées plus tard
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated;

-- 1) Tables cibles de l’app (ajoute/retire si besoin)
DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'prospects',
    'profiles',
    'list_batches',
    'campaign_targets',
    'campaigns',
    'opportunity_milestones',
    'appointments',
    'call_logs',
    'documents',
    'email_events',
    'email_templates',
    'prospect_stage_history',
    'validation_steps',
    'geo_city_index',
    'campaign_members'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    -- GRANT DML complets
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated;', t);

    -- Activer RLS si pas déjà fait
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);

    -- Policies (CREATE IF NOT EXISTS via garde)
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND policyname='read_'||t||'_auth'
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true);',
        'read_'||t||'_auth', t
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND policyname='ins_'||t||'_auth'
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (true);',
        'ins_'||t||'_auth', t
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND policyname='upd_'||t||'_auth'
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (true) WITH CHECK (true);',
        'upd_'||t||'_auth', t
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND policyname='del_'||t||'_auth'
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (true);',
        'del_'||t||'_auth', t
      );
    END IF;
  END LOOP;
END$$;

-- 2) Table de staging (si tu veux aussi la passer sous RLS "ouvert")
-- (Tu avais déjà des GRANT DML; RLS était "Unrestricted" côté Studio.
--  Choisis l’un OU l’autre. Si tu veux RLS ON + policies ouvertes, utilise ça:)
DO $$
BEGIN
  IF to_regclass('public.staging_raw_prospects') IS NOT NULL THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.staging_raw_prospects TO authenticated;
    ALTER TABLE public.staging_raw_prospects ENABLE ROW LEVEL SECURITY;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='staging_raw_prospects' AND policyname='read_staging_auth'
    ) THEN
      CREATE POLICY read_staging_auth ON public.staging_raw_prospects
        FOR SELECT TO authenticated USING (true);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='staging_raw_prospects' AND policyname='ins_staging_auth'
    ) THEN
      CREATE POLICY ins_staging_auth ON public.staging_raw_prospects
        FOR INSERT TO authenticated WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='staging_raw_prospects' AND policyname='upd_staging_auth'
    ) THEN
      CREATE POLICY upd_staging_auth ON public.staging_raw_prospects
        FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename='staging_raw_prospects' AND policyname='del_staging_auth'
    ) THEN
      CREATE POLICY del_staging_auth ON public.staging_raw_prospects
        FOR DELETE TO authenticated USING (true);
    END IF;
  END IF;
END$$;

-- 3) (Optionnel) lecture publique pour quelques vues/pages publiques
-- CREATE POLICY read_prospects_anon ON public.prospects FOR SELECT TO anon USING (true);
