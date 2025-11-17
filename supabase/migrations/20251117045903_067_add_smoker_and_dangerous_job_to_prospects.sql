-- Ajout des infos de risque perso sur le prospect principal
ALTER TABLE public.prospects
  ADD COLUMN is_smoker boolean,
  ADD COLUMN dangerous_job boolean;

COMMENT ON COLUMN public.prospects.is_smoker IS 'Prospect fumeur (true/false, null = non renseigné)';
COMMENT ON COLUMN public.prospects.dangerous_job IS 'Prospect avec métier à risque (true/false, null = non renseigné)';