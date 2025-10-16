set search_path = public;

-- 1) Vue des campagnes visibles pour l'utilisateur courant (opérateur = strict)
create or replace view public.campaigns_for_current_user
with (security_invoker=true)
as
select distinct c.*
from public.campaigns c
join public.campaign_targets ct on ct.campaign_id = c.id
where ct.assigned_to = auth.uid()
union
select c.*  -- managers/admin voient tout via policy campaigns_select_can_read déjà en place
from public.campaigns c
where public.is_manager_or_admin();

-- 2) Campaigns: on garde ta policy "can_read_campaign" (037) – rien à changer.

-- 3) Campaign_targets: lecture strict = seulement mes lignes (ou manager/admin)
do $$
begin
  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='campaign_targets'
      and policyname='campaign_targets_select_can_read'
  ) then
    drop policy campaign_targets_select_can_read on public.campaign_targets;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='campaign_targets'
      and policyname='campaign_targets_select_strict'
  ) then
    create policy campaign_targets_select_strict
      on public.campaign_targets
      for select
      to authenticated
      using (
        public.is_manager_or_admin()
        or assigned_to = auth.uid()
      );
  end if;
end$$;

-- 4) Prospects: lecture strict = seulement ceux dont je suis owner (ou manager/admin)
-- (Si tu as déjà une policy équivalente, garde la plus restrictive.)
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='prospects'
      and policyname='prospects_select_owner_or_manager'
  ) then
    create policy prospects_select_owner_or_manager
      on public.prospects
      for select
      to authenticated
      using ( public.is_manager_or_admin() or owner_id = auth.uid() );
  end if;
end$$;

-- 5) List_batches: empêcher la lecture pour les opérateurs (réservé admin/manager)
alter table public.list_batches enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='list_batches'
      and policyname='list_batches_select_manager_only'
  ) then
    create policy list_batches_select_manager_only
      on public.list_batches
      for select
      to authenticated
      using ( public.is_manager_or_admin() );
  end if;
end$$;

-- 6) Grant (lecture OK, RLS filtre)
grant select on public.campaigns, public.campaign_targets, public.prospects, public.list_batches
  to authenticated;
