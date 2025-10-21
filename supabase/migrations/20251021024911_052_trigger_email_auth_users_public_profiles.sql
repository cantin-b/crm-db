-- 1) Fonction dans PUBLIC (pas dans AUTH)
create or replace function public.sync_user_email_to_profile()
returns trigger
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
begin
  -- No-op si l'email ne change pas
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;

  -- Propager vers public.profiles
  update public.profiles
     set email = new.email
   where id = new.id;

  return new;
end;
$$;

-- 2) Trigger sur auth.users lorsque l'email change
drop trigger if exists trg_sync_user_email_to_profile on auth.users;
create trigger trg_sync_user_email_to_profile
after update of email on auth.users
for each row
execute function public.sync_user_email_to_profile();

-- 3) Backfill immédiat (optionnel, pour recoller l'existant)
update public.profiles p
   set email = u.email
  from auth.users u
 where p.id = u.id
   and p.email is distinct from u.email;