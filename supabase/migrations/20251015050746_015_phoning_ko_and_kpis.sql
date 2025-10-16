set search_path = public;

-- 1) Ajouter 'KO' à l'énum phoning si besoin
do $$
declare
  t_name text := 'phoning_disposition_enum';
  has_type boolean;
  has_ko boolean;
begin
  select exists (select 1 from pg_type where typname = t_name) into has_type;

  if has_type then
    select exists (
      select 1 from pg_type t
      join pg_enum e on e.enumtypid = t.oid
      where t.typname = t_name and e.enumlabel = 'KO'
    ) into has_ko;

    if not has_ko then
      execute format('alter type %I add value %L', t_name, 'KO');
    end if;
  else
    perform 1;
  end if;
end$$;

-- 2) RPC : marquer KO
create or replace function public.prospect_mark_ko(p_prospect_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.prospects
     set stage = 'PHONING',
         phoning_disposition = 'KO',
         stage_changed_at = now(),
         ko_reason = p_reason
   where id = p_prospect_id;

  if p_reason is not null then
    update public.prospects
       set comments = coalesce(comments,'') || E'\n— KO: ' || p_reason
     where id = p_prospect_id;
  end if;
end;
$$;

-- 3) KPI minimalistes (période & filtre opérateur optionnel)
-- Hypothèses:
--  - prospects(created_at, stage, stage_changed_at, phoning_disposition, owner_id, updated_at)
--  - call_logs(prospect_id, operator_id, created_at)
--  - appointments(status, start_at, created_at, prospect_id, user_id)
--  - opportunity_milestones(quote_sent_at, prospect_id)
create or replace function public.kpi_counters(
  p_from timestamptz,
  p_to   timestamptz,
  p_operator_id uuid default null
)
returns table(
  leads   bigint,
  calls   bigint,
  rdv     bigint,
  quotes  bigint,
  signed  bigint,
  refused bigint
)
language sql
set search_path = public
as $$
  with
  f_leads as (
    select count(*)::bigint c
    from prospects p
    where p.created_at >= p_from and p.created_at < p_to
      and (p_operator_id is null or p.owner_id = p_operator_id)
  ),
  f_calls as (
    select count(*)::bigint c
    from call_logs cl
    where cl.created_at >= p_from and cl.created_at < p_to
      and (p_operator_id is null or cl.operator_id = p_operator_id)
  ),
  f_rdv as (
    select count(*)::bigint c
    from appointments a
    where a.created_at >= p_from and a.created_at < p_to
      and (p_operator_id is null or a.user_id = p_operator_id)
  ),
  f_quotes as (
    select count(*)::bigint c
    from opportunity_milestones m
    where m.quote_sent_at is not null
      and m.quote_sent_at >= p_from and m.quote_sent_at < p_to
  ),
  f_signed as (
    select count(*)::bigint c
    from prospects p
    where p.stage = 'CONTRACT'
      and p.stage_changed_at >= p_from and p.stage_changed_at < p_to
      and (p_operator_id is null or p.owner_id = p_operator_id)
  ),
  f_refused as (
    select count(*)::bigint c
    from prospects p
    where p.stage = 'PHONING'
      and coalesce(p.phoning_disposition::text,'') in ('REFUS','KO')
      and p.updated_at >= p_from and p.updated_at < p_to
      and (p_operator_id is null or p.owner_id = p_operator_id)
  )
  select
    (select c from f_leads),
    (select c from f_calls),
    (select c from f_rdv),
    (select c from f_quotes),
    (select c from f_signed),
    (select c from f_refused);
$$;
