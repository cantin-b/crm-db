create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  first_name  text,
  last_name   text,
  username    text,
  email       text,
  role        app_role not null default 'operator',
  created_at  timestamptz not null default now()
);

create table if not exists public.list_batches (
  id           bigserial primary key,
  label        text not null,
  obtained_on  date,
  source       source_enum,
  size_hint    int,
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

create table if not exists public.prospects (
  id                      uuid primary key default gen_random_uuid(),
  list_batch_id           bigint references public.list_batches(id) on delete set null,

  first_name              text,
  last_name               text,
  civility                text,
  birth_date              date,

  address1                text,
  address2                text,
  postal_code             text,
  city                    text,

  email                   text,
  phone_e164              text,

  net_salary              numeric,
  co_borrower             boolean,
  co_net_salary           numeric,

  comments                text,
  annexes                 text,
  annexes_private         boolean not null default false,
  annexes_lock_owner_id   uuid references public.profiles(id) on delete set null,

  call_count              int not null default 0,
  last_call_at            timestamptz,

  source                  source_enum,
  owner_id                uuid references public.profiles(id) on delete set null,

  stage                   stage_enum not null default 'PHONING',
  stage_changed_at        timestamptz,
  archived_at             timestamptz,
  ko_reason               text,

  phoning_disposition     phoning_disposition_enum,
  docs_status             docs_status_enum,
  validation_step         validation_step_enum,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
