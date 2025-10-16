create table if not exists public.email_templates (
  id            bigserial primary key,
  template_key  text unique not null,
  subject       text,
  body_md       text
);

create table if not exists public.email_events (
  id            bigserial primary key,
  template_key  text references public.email_templates(template_key) on delete set null,
  prospect_id   uuid references public.prospects(id) on delete cascade,
  user_id       uuid references public.profiles(id) on delete set null,
  sent_at       timestamptz not null default now()
);
