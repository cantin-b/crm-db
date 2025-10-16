-- MIGRATION: update_appointment_plan_reschedule
-- Objectif: replanifier = update la ligne PLANNED existante (KPIs inchangés).
create or replace function public.appointment_plan(
  p_prospect_id uuid,
  p_start_at timestamptz,
  p_user_id uuid default null
) returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id bigint;
begin
  -- 1) Tenter d'écraser le dernier RDV PLANNED
  update public.appointments
     set start_at   = p_start_at,
         user_id    = coalesce(p_user_id, user_id),
         updated_at = now()
   where id = (
     select id
       from public.appointments
      where prospect_id = p_prospect_id
        and status = 'PLANNED'
      order by created_at desc, id desc
      limit 1
   )
   returning id into v_id;

  -- 2) S'il n'y en a pas, on crée
  if v_id is null then
    insert into public.appointments (prospect_id, user_id, start_at, status)
    values (p_prospect_id, p_user_id, p_start_at, 'PLANNED')
    returning id into v_id;
  end if;

  return v_id;
end
$$;

-- Index utile pour filtres par prospect/status/date
create index if not exists idx_appointments_prospect_status_start
  on public.appointments (prospect_id, status, start_at);
