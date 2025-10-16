set search_path = public;

-- 1) Helper centralisé
create or replace function public.can_read_campaign(p_campaign_id bigint)
returns boolean
language sql
stable
security invoker
as $$
  select
    public.is_manager_or_admin()
    or exists (
      select 1 from public.campaign_members cm
      where cm.campaign_id = p_campaign_id
        and cm.user_id = auth.uid()
    )
    or exists (
      select 1 from public.campaign_targets ct
      where ct.campaign_id = p_campaign_id
        and ct.assigned_to = auth.uid()
    );
$$;

-- 2) campaign_targets: SELECT lisible si on peut lire la campagne
do $$
begin
  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='campaign_targets'
      and policyname='campaign_targets_select_by_assignee_or_admin'
  ) then
    execute 'drop policy campaign_targets_select_by_assignee_or_admin on public.campaign_targets';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='campaign_targets'
      and policyname='campaign_targets_select_can_read'
  ) then
    execute $POL$
      create policy campaign_targets_select_can_read
      on public.campaign_targets
      for select
      to authenticated
      using ( public.can_read_campaign(campaign_targets.campaign_id) );
    $POL$;
  end if;
end$$;

-- 3) campaigns: SELECT lisible si can_read_campaign(id)
do $$
begin
  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='campaigns'
      and policyname='campaigns_select_by_members_or_assignees'
  ) then
    execute 'drop policy campaigns_select_by_members_or_assignees on public.campaigns';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='campaigns'
      and policyname='campaigns_select_can_read'
  ) then
    execute $POL$
      create policy campaigns_select_can_read
      on public.campaigns
      for select
      to authenticated
      using ( public.can_read_campaign(campaigns.id) );
    $POL$;
  end if;
end$$;

-- 4) RLS bien activée + droits de lecture
alter table public.campaigns enable row level security;
alter table public.campaign_targets enable row level security;

grant select on public.campaigns        to authenticated;
grant select on public.campaign_targets to authenticated;
