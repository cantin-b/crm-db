-- 014_appointments.sql (sans updated_at)
set search_path = public;

-- Enum statut de RDV
do $$ begin
  create type appointment_status as enum ('PLANNED','DONE','NO_SHOW','CANCELED');
exception when duplicate_object then null; end $$;

-- Colonnes supplémentaires sur la table existante
-- Table existante (depuis 003) : id(bigserial), prospect_id, user_id, start_at, end_at, title, notes, created_at
alter table public.appointments
  add column if not exists status appointment_status not null default 'PLANNED',
  add column if not exists attended_at timestamptz;

-- Index
create index if not exists idx_appointments_prospect  on public.appointments(prospect_id);
create index if not exists idx_appointments_start     on public.appointments(start_at);
create index if not exists idx_appointments_status    on public.appointments(status);

-- Un seul RDV "PLANNED" actif par prospect
do $$
begin
  -- L'index unique partiel peut déjà exister; on le crée si absent.
  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and indexname = 'uniq_planned_rdv_per_prospect'
  ) then
    execute '
      create unique index uniq_planned_rdv_per_prospect
        on public.appointments(prospect_id)
        where status = ''PLANNED''
    ';
  end if;
end$$;

-- Vue : dernier RDV (quel que soit le statut) par prospect
create or replace view public.latest_appointment_per_prospect as
select distinct on (a.prospect_id)
  a.prospect_id,
  a.id           as appointment_id,
  a.start_at     as scheduled_at,
  a.status,
  a.attended_at,
  a.created_at
from public.appointments a
order by a.prospect_id, a.start_at desc, a.created_at desc;

-- RPC : planifier un RDV (annule les PLANNED existants, insère un nouveau PLANNED)
create or replace function public.appointment_plan(
  p_prospect_id uuid,
  p_start_at timestamptz,
  p_user_id uuid default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_id bigint;
begin
  -- Annuler les RDV encore PLANNED (on garde l'historique)
  update public.appointments
     set status = 'CANCELED'
   where prospect_id = p_prospect_id
     and status = 'PLANNED';

  insert into public.appointments(prospect_id, user_id, start_at, status)
  values (p_prospect_id, p_user_id, p_start_at, 'PLANNED')
  returning id into v_id;

  return v_id;
end;
$$;

-- RPC : clôturer le dernier RDV PLANNED en DONE ou NO_SHOW
create or replace function public.appointment_close_latest(
  p_prospect_id uuid,
  p_outcome text  -- 'DONE' | 'NO_SHOW'
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_id bigint;
begin
  if upper(p_outcome) not in ('DONE','NO_SHOW') then
    raise exception 'Outcome invalide: % (attendu: DONE | NO_SHOW)', p_outcome;
  end if;

  update public.appointments
     set status = upper(p_outcome)::appointment_status,
         attended_at = case when upper(p_outcome) = 'DONE' then now() else attended_at end
   where id = (
     select id from public.appointments
      where prospect_id = p_prospect_id
        and status = 'PLANNED'
      order by start_at desc, created_at desc
      limit 1
   )
   returning id into v_id;

  if v_id is null then
    raise exception 'Aucun RDV PLANNED à clôturer pour ce prospect';
  end if;

  return v_id;
end;
$$;
