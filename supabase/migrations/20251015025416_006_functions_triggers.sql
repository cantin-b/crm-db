-- updated_at automaton
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_prospects_updated_at on public.prospects;
create trigger trg_prospects_updated_at
before update on public.prospects
for each row execute function public.set_updated_at();

-- call duration auto-calc
create or replace function public.set_call_duration()
returns trigger language plpgsql as $$
begin
  if new.ended_at is not null then
    new.duration_seconds := greatest(0, extract(epoch from (new.ended_at - new.started_at)))::int;
  end if;
  return new;
end $$;

drop trigger if exists trg_call_logs_duration on public.call_logs;
create trigger trg_call_logs_duration
before insert or update on public.call_logs
for each row execute function public.set_call_duration();

-- stage-change journaling (+ stamp stage_changed_at)
create or replace function public.log_stage_change()
returns trigger language plpgsql as $$
begin
  if new.stage is distinct from old.stage then
    new.stage_changed_at := now();
    insert into public.prospect_stage_history
      (prospect_id, from_stage, to_stage, changed_at, changed_by, note)
    values (old.id, old.stage, new.stage, now(), auth.uid(), null);
  end if;
  return new;
end $$;

drop trigger if exists trg_stage_change on public.prospects;
create trigger trg_stage_change
before update on public.prospects
for each row execute function public.log_stage_change();

-- Role helpers (SECURITY DEFINER to avoid RLS recursion)
create or replace function public.current_app_role()
returns app_role
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'operator')::app_role
$$;

create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select public.current_app_role() = 'admin'
$$;

create or replace function public.is_manager_or_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select public.current_app_role() in ('admin','manager')
$$;

-- Auth -> Profiles sync (first_name, last_name, username)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_first text := nullif(new.raw_user_meta_data->>'first_name','');
  v_last  text := nullif(new.raw_user_meta_data->>'last_name','');
  v_user  text := coalesce(
                   nullif(new.raw_user_meta_data->>'username',''),
                   split_part(lower(new.email),'@',1)
                 );
begin
  insert into public.profiles (id, first_name, last_name, username, email, role, created_at)
  values (new.id, v_first, v_last, v_user, new.email, 'operator', now())
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- one-time backfill from auth.users
insert into public.profiles (id, first_name, last_name, username, email, role, created_at)
select u.id,
       nullif(u.raw_user_meta_data->>'first_name','') as first_name,
       nullif(u.raw_user_meta_data->>'last_name','')  as last_name,
       coalesce(nullif(u.raw_user_meta_data->>'username',''), split_part(lower(u.email),'@',1)) as username,
       u.email,
       'operator',
       now()
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;
