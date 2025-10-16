-- Migration 047: campaign_transfer_targets (global owner update)
-- Étend la fonction pour mettre aussi à jour prospects.owner_id quand on remplace un opérateur.

create or replace function public.campaign_transfer_targets(
  p_campaign_id bigint,
  p_from uuid,
  p_to uuid,
  p_cancel_future_appts boolean default true
)
returns table(transferred integer, appts_canceled integer)
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_transferred int := 0;
  v_canceled    int := 0;
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;

  -- 1) Transfert global d’ownership (prospects.owner_id)
  update public.prospects p
     set owner_id = p_to
   where p.owner_id = p_from
     and exists (
       select 1
         from public.campaign_targets ct
        where ct.campaign_id = p_campaign_id
          and ct.prospect_id = p.id
     );

  -- 2) Miroir sur campaign_targets
  update public.campaign_targets t
     set assigned_to = p_to
   where t.campaign_id = p_campaign_id
     and t.assigned_to = p_from;
  get diagnostics v_transferred = row_count;

  -- 3) Annule les RDV futurs de l’opérateur remplacé si demandé
  if p_cancel_future_appts then
    update public.appointments a
       set status = 'CANCELED'
     where a.status = 'PLANNED'
       and a.user_id = p_from
       and a.prospect_id in (
         select prospect_id
           from public.campaign_targets
          where campaign_id = p_campaign_id
       );
    get diagnostics v_canceled = row_count;
  end if;

  return query select v_transferred, v_canceled;
end
$$;

comment on function public.campaign_transfer_targets(bigint, uuid, uuid, boolean) is
  'Transfert global d’affectation pour une campagne : met à jour campaign_targets.assigned_to et prospects.owner_id.';
