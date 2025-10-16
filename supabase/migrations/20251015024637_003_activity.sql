create table if not exists public.call_logs (
  id                bigserial primary key,
  prospect_id       uuid references public.prospects(id) on delete cascade,
  operator_id       uuid references public.profiles(id) on delete set null,
  campaign_id       bigint references public.campaigns(id) on delete set null,

  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  duration_seconds  int,

  outcome           call_outcome_enum,
  disposition       call_disposition_enum not null default 'none',
  note              text,
  next_callback_at  timestamptz,
  created_at        timestamptz not null default now(),

  constraint call_time_order_chk check (ended_at is null or ended_at >= started_at)
);

create table if not exists public.documents (
  id           bigserial primary key,
  prospect_id  uuid references public.prospects(id) on delete cascade,
  doc_type     text,
  status       text,
  file_path    text,
  uploaded_by  uuid references public.profiles(id) on delete set null,
  uploaded_at  timestamptz not null default now()
);

create table if not exists public.appointments (
  id           bigserial primary key,
  prospect_id  uuid references public.prospects(id) on delete cascade,
  user_id      uuid references public.profiles(id) on delete set null,
  start_at     timestamptz not null,
  end_at       timestamptz,
  title        text,
  notes        text,
  created_at   timestamptz not null default now()
);
