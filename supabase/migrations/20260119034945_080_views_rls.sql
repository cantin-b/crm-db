-- 080_rls_views_security_invoker.sql

-- 1) Toujours une bonne idée de s'assurer que les rôles ont le droit de SELECT sur les views
-- (souvent déjà OK via GRANTs existants, mais là c'est explicite)
grant select on public.campaigns_for_current_user to authenticated;
grant select on public.latest_appointment_per_prospect to authenticated;
grant select on public.v_docs_collection_stats to authenticated;
grant select on public.v_next_planned_appointment to authenticated;

-- 2) Le coeur : forcer les views à s’exécuter avec les droits de l’appelant
-- => applique les RLS des tables sous-jacentes
alter view public.campaigns_for_current_user set (security_invoker = true);
alter view public.latest_appointment_per_prospect set (security_invoker = true);
alter view public.v_docs_collection_stats set (security_invoker = true);
alter view public.v_next_planned_appointment set (security_invoker = true);