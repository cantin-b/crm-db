set search_path = public;

-- ------------------------------------------------------------
-- RPC 1 : transférer les cibles d'un opérateur A vers B
--         + annuler les RDV PLANNED de A sur ces prospects
-- ------------------------------------------------------------
create or replace function public.campaign_transfer_targets(
  p_campaign_id bigint,
  p_from uuid,
  p_to uuid,
  p_cancel_future_appts boolean default true
) returns table(transferred int, appts_canceled int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transferred int := 0;
  v_canceled    int := 0;
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;

  update public.campaign_targets t
     set assigned_to = p_to
   where t.campaign_id = p_campaign_id
     and t.assigned_to = p_from;
  get diagnostics v_transferred = row_count;

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
end $$;

-- ------------------------------------------------------------
-- RPC 2 : un opérateur reprend l'ensemble d'une campagne
--         + annuler les RDV PLANNED existants (optionnel)
-- ------------------------------------------------------------
create or replace function public.campaign_takeover(
  p_campaign_id bigint,
  p_new_owner uuid,
  p_cancel_future_appts boolean default true
) returns table(transferred int, appts_canceled int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transferred int := 0;
  v_canceled    int := 0;
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;

  update public.campaign_targets
     set assigned_to = p_new_owner
   where campaign_id = p_campaign_id;
  get diagnostics v_transferred = row_count;

  if p_cancel_future_appts then
    update public.appointments a
       set status = 'CANCELED'
     where a.status = 'PLANNED'
       and a.prospect_id in (
         select prospect_id
           from public.campaign_targets
          where campaign_id = p_campaign_id
       );
    get diagnostics v_canceled = row_count;
  end if;

  return query select v_transferred, v_canceled;
end $$;

-- ------------------------------------------------------------
-- Garde-fou RLS : empêcher l'insertion d'un call_log
-- par un opérateur ≠ assigned_to sur une campagne ACTIVE
-- ------------------------------------------------------------
alter table public.call_logs enable row level security;

drop policy if exists ins_calls on public.call_logs;
drop policy if exists upd_calls on public.call_logs;

create policy ins_calls on public.call_logs
  for insert
  with check (
    public.is_manager_or_admin()
    or (
      operator_id = auth.uid()
      and not exists (
        select 1
          from public.campaign_targets t
          join public.campaigns c on c.id = t.campaign_id
         where t.prospect_id = call_logs.prospect_id
           and c.status = 'ACTIVE'
           and t.assigned_to is not null
           and t.assigned_to <> auth.uid()
      )
    )
  );

create policy upd_calls on public.call_logs
  for update
  using (public.is_manager_or_admin() or operator_id = auth.uid())
  with check (public.is_manager_or_admin() or operator_id = auth.uid());
