alter table public.prospects
  add column if not exists phoning_failed_attempts_count int not null default 0,
  add column if not exists phoning_last_failed_at timestamptz,
  add column if not exists phoning_last_failed_code phoning_disposition_enum;

create or replace function public.map_outcome_to_failed_code(outcome call_outcome_enum)
returns phoning_disposition_enum
language sql immutable as $$
  select case $1
    when 'no_answer' then 'NRP'::phoning_disposition_enum
    when 'voicemail' then 'REPONDEUR'::phoning_disposition_enum
    when 'busy'      then 'MAUVAISE_COMM'::phoning_disposition_enum
    else null::phoning_disposition_enum
  end
$$;

create or replace function public.bump_failed_attempts_from_call()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare code phoning_disposition_enum; ts timestamptz;
begin
  ts := coalesce(new.ended_at, new.started_at, now());

  if new.outcome = 'answered' then
    update public.prospects p
       set phoning_failed_attempts_count = 0
     where p.id = new.prospect_id;
    return new;
  end if;

  code := public.map_outcome_to_failed_code(new.outcome);

  if code is not null then
    update public.prospects p
       set phoning_failed_attempts_count = p.phoning_failed_attempts_count + 1,
           phoning_last_failed_at       = ts,
           phoning_last_failed_code     = code
     where p.id = new.prospect_id
       and p.stage = 'PHONING';
  end if;
  return new;
end $$;

drop trigger if exists trg_call_failed_attempts on public.call_logs;
create trigger trg_call_failed_attempts
after insert on public.call_logs
for each row execute function public.bump_failed_attempts_from_call();

create or replace function public.recount_failed_attempts(p_prospect_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_prospect_id is null then
    update public.prospects p
       set phoning_failed_attempts_count = coalesce((
             select count(1) from public.call_logs c
              where c.prospect_id = p.id
                and public.map_outcome_to_failed_code(c.outcome) is not null
           ),0),
           phoning_last_failed_at = (
             select max(coalesce(c.ended_at, c.started_at))
               from public.call_logs c
              where c.prospect_id = p.id
                and public.map_outcome_to_failed_code(c.outcome) is not null
           ),
           phoning_last_failed_code = (
             select public.map_outcome_to_failed_code(c.outcome)
               from public.call_logs c
              where c.prospect_id = p.id
                and public.map_outcome_to_failed_code(c.outcome) is not null
              order by coalesce(c.ended_at, c.started_at) desc
              limit 1
           );
  else
    update public.prospects p
       set phoning_failed_attempts_count = coalesce((
             select count(1) from public.call_logs c
              where c.prospect_id = p_prospect_id
                and public.map_outcome_to_failed_code(c.outcome) is not null
           ),0),
           phoning_last_failed_at = (
             select max(coalesce(c.ended_at, c.started_at))
               from public.call_logs c
              where c.prospect_id = p_prospect_id
                and public.map_outcome_to_failed_code(c.outcome) is not null
           ),
           phoning_last_failed_code = (
             select public.map_outcome_to_failed_code(c.outcome)
               from public.call_logs c
              where c.prospect_id = p_prospect_id
                and public.map_outcome_to_failed_code(c.outcome) is not null
              order by coalesce(c.ended_at, c.started_at) desc
              limit 1
           )
     where p.id = p_prospect_id;
  end if;
end $$;
