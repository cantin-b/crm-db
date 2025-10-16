create table if not exists public.prospect_stage_history (
  id          bigserial primary key,
  prospect_id uuid references public.prospects(id) on delete cascade,
  from_stage  stage_enum,
  to_stage    stage_enum,
  changed_at  timestamptz not null default now(),
  changed_by  uuid references public.profiles(id) on delete set null,
  note        text
);

create table if not exists public.opportunity_milestones (
  prospect_id             uuid primary key references public.prospects(id) on delete cascade,
  docs_requested_at       timestamptz,
  docs_first_received_at  timestamptz,
  docs_completed_at       timestamptz,
  quote_sent_at           timestamptz,
  quote_signed_at         timestamptz,
  last_reminder_at        timestamptz,
  reminder_count          int default 0
);

create table if not exists public.validation_steps (
  id          bigserial primary key,
  prospect_id uuid references public.prospects(id) on delete cascade,
  step        validation_step_enum not null,
  done_at     timestamptz not null default now(),
  in_progress boolean default false,
  note        text
);
create unique index if not exists validation_steps_unique
  on public.validation_steps (prospect_id, step);
