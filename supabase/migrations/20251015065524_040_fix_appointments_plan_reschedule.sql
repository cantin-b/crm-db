-- see content inserted by assistant above
-- 040_fix_appointments_plan_reschedule.sql

create or replace function public.appointment_reschedule(
  p_appointment_id bigint,
  p_start_at timestamptz,
  p_user_id uuid default null
) returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_status public.appointment_status;
begin
  select status into v_status from public.appointments where id = p_appointment_id;
  if v_status is null then
    raise exception 'RDV introuvable (%).', p_appointment_id;
  end if;
  if v_status <> 'PLANNED' then
    raise exception 'Seul un RDV PLANNED peut être replanifié (id=%; status=%).', p_appointment_id, v_status;
  end if;

  update public.appointments
     set start_at   = p_start_at,
         user_id    = coalesce(p_user_id, user_id),
         updated_at = now()
   where id = p_appointment_id;

  return p_appointment_id;
end
$$;

create or replace function public.appointment_plan(
  p_prospect_id uuid,
  p_start_at timestamptz,
  p_user_id uuid default null
) returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_id bigint;
begin
  insert into public.appointments (prospect_id, user_id, start_at, status)
  values (p_prospect_id, p_user_id, p_start_at, 'PLANNED')
  returning id into v_id;

  return v_id;
end
$$;

create or replace view public.v_next_planned_appointment as
select a.*
from public.appointments a
join (
  select prospect_id, min(start_at) as next_start
  from public.appointments
  where status = 'PLANNED'
  group by prospect_id
) x
  on x.prospect_id = a.prospect_id
 and x.next_start  = a.start_at
where a.status = 'PLANNED';
