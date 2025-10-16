create table if not exists public.campaigns (
  id          bigserial primary key,
  name        text not null,
  start_at    date,
  end_at      date,
  filter_json jsonb,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.campaign_members (
  campaign_id bigint references public.campaigns(id) on delete cascade,
  user_id     uuid   references public.profiles(id) on delete cascade,
  primary key (campaign_id, user_id)
);

create table if not exists public.campaign_targets (
  id           bigserial primary key,
  campaign_id  bigint references public.campaigns(id) on delete cascade,
  prospect_id  uuid   references public.prospects(id) on delete cascade,
  assigned_to  uuid   references public.profiles(id) on delete set null,
  status       text,
  created_at   timestamptz not null default now()
);
