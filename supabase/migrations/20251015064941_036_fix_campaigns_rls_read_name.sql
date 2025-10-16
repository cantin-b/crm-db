set search_path = public;

-- ⚙️ Donner aux opérateurs/membres le droit de lire le nom des campagnes
-- via la jointure PostgREST campaign:campaigns(name)

-- Crée une policy SELECT supplémentaire (OR avec les éventuelles existantes) :
-- - managers/admin via public.is_manager_or_admin()
-- - membres de la campagne via campaign_members
-- - opérateurs avec au moins un target assigné via campaign_targets

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'campaigns'
      and policyname = 'campaigns_select_by_members_or_assignees'
  ) then
    execute $pol$
      create policy campaigns_select_by_members_or_assignees
      on public.campaigns
      for select
      to authenticated
      using (
        public.is_manager_or_admin()
        or exists (
          select 1 from public.campaign_members cm
          where cm.campaign_id = campaigns.id
            and cm.user_id = auth.uid()
        )
        or exists (
          select 1 from public.campaign_targets ct
          where ct.campaign_id = campaigns.id
            and ct.assigned_to = auth.uid()
        )
      );
    $pol$;
  end if;
end$$;

-- (Optionnel/robuste) S'assurer que les opérateurs peuvent bien lire leurs targets
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'campaign_targets'
      and policyname = 'campaign_targets_select_by_assignee_or_admin'
  ) then
    execute $pol$
      create policy campaign_targets_select_by_assignee_or_admin
      on public.campaign_targets
      for select
      to authenticated
      using (
        public.is_manager_or_admin()
        or assigned_to = auth.uid()
      );
    $pol$;
  end if;
end$$;

-- Rien à faire pour INSERT/UPDATE ici.
-- On ne touche pas aux autres policies existantes (OR logique).
