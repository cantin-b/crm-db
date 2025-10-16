alter table public.profiles                enable row level security;
alter table public.list_batches            enable row level security;
alter table public.prospects               enable row level security;
alter table public.campaigns               enable row level security;
alter table public.campaign_members        enable row level security;
alter table public.campaign_targets        enable row level security;
alter table public.call_logs               enable row level security;
alter table public.documents               enable row level security;
alter table public.appointments            enable row level security;
alter table public.email_templates         enable row level security;
alter table public.email_events            enable row level security;
alter table public.prospect_stage_history  enable row level security;
alter table public.opportunity_milestones  enable row level security;
alter table public.validation_steps        enable row level security;

-- profiles
drop policy if exists sel_profiles_self  on public.profiles;
drop policy if exists sel_profiles_admin on public.profiles;
drop policy if exists upd_profiles       on public.profiles;

create policy sel_profiles_self  on public.profiles for select using (id = auth.uid());
create policy sel_profiles_admin on public.profiles for select using (public.is_manager_or_admin());
create policy upd_profiles       on public.profiles for update using (id = auth.uid() or public.is_admin());

-- list_batches
drop policy if exists sel_list_batches on public.list_batches;
drop policy if exists mod_list_batches on public.list_batches;
create policy sel_list_batches on public.list_batches for select using (true);
create policy mod_list_batches on public.list_batches
  for all using (public.is_manager_or_admin()) with check (public.is_manager_or_admin());

-- prospects
drop policy if exists sel_prospects on public.prospects;
drop policy if exists mod_prospects on public.prospects;
drop policy if exists upd_prospects on public.prospects;
drop policy if exists del_prospects on public.prospects;

create policy sel_prospects on public.prospects
for select using (
  public.is_manager_or_admin()
  or owner_id = auth.uid()
  or exists (
    select 1 from public.campaign_targets t
     where t.prospect_id = prospects.id and t.assigned_to = auth.uid()
  )
  or (not annexes_private)
);

create policy mod_prospects on public.prospects
  for insert with check (public.is_manager_or_admin() or owner_id = auth.uid());

create policy upd_prospects on public.prospects
  for update using (public.is_manager_or_admin() or owner_id = auth.uid())
          with check (public.is_manager_or_admin() or owner_id = auth.uid());

create policy del_prospects on public.prospects
  for delete using (public.is_manager_or_admin());

-- campaigns
drop policy if exists sel_campaigns on public.campaigns;
drop policy if exists mod_campaigns on public.campaigns;
create policy sel_campaigns on public.campaigns for select using (true);
create policy mod_campaigns on public.campaigns
  for all using (public.is_manager_or_admin()) with check (public.is_manager_or_admin());

-- campaign_members
drop policy if exists sel_cmembers on public.campaign_members;
drop policy if exists mod_cmembers on public.campaign_members;
create policy sel_cmembers on public.campaign_members for select using (true);
create policy mod_cmembers on public.campaign_members
  for all using (public.is_manager_or_admin()) with check (public.is_manager_or_admin());

-- campaign_targets
drop policy if exists sel_targets on public.campaign_targets;
drop policy if exists mod_targets on public.campaign_targets;
create policy sel_targets on public.campaign_targets
  for select using (public.is_manager_or_admin() or assigned_to = auth.uid());
create policy mod_targets on public.campaign_targets
  for all using (public.is_manager_or_admin()) with check (public.is_manager_or_admin());

-- call_logs
drop policy if exists sel_calls on public.call_logs;
drop policy if exists ins_calls on public.call_logs;
drop policy if exists upd_calls on public.call_logs;
create policy sel_calls on public.call_logs
  for select using (public.is_manager_or_admin() or operator_id = auth.uid());
create policy ins_calls on public.call_logs
  for insert with check (public.is_manager_or_admin() or operator_id = auth.uid());
create policy upd_calls on public.call_logs
  for update using (public.is_manager_or_admin() or operator_id = auth.uid())
           with check (public.is_manager_or_admin() or operator_id = auth.uid());

-- documents
drop policy if exists sel_docs on public.documents;
drop policy if exists mod_docs on public.documents;
create policy sel_docs on public.documents
  for select using (
    public.is_manager_or_admin()
    or exists (
      select 1 from public.prospects p
       where p.id = documents.prospect_id
         and (p.owner_id = auth.uid()
           or exists (select 1 from public.campaign_targets t
                      where t.prospect_id = p.id and t.assigned_to = auth.uid()))
    )
  );

create policy mod_docs on public.documents
  for all using (
    public.is_manager_or_admin()
    or exists (select 1 from public.prospects p where p.id = documents.prospect_id and p.owner_id = auth.uid())
  ) with check (
    public.is_manager_or_admin()
    or exists (select 1 from public.prospects p where p.id = documents.prospect_id and p.owner_id = auth.uid())
  );

-- appointments
drop policy if exists sel_appt on public.appointments;
drop policy if exists mod_appt on public.appointments;
create policy sel_appt on public.appointments
  for select using (
    public.is_manager_or_admin() or user_id = auth.uid()
    or exists (select 1 from public.prospects p where p.id = appointments.prospect_id and p.owner_id = auth.uid())
  );
create policy mod_appt on public.appointments
  for all using (public.is_manager_or_admin() or user_id = auth.uid())
        with check (public.is_manager_or_admin() or user_id = auth.uid());

-- email
drop policy if exists sel_et on public.email_templates;
create policy sel_et on public.email_templates for select using (true);

drop policy if exists sel_ee on public.email_events;
drop policy if exists mod_ee on public.email_events;
create policy sel_ee on public.email_events for select using (true);
create policy mod_ee on public.email_events
  for insert with check (public.is_manager_or_admin() or user_id = auth.uid());

-- history / milestones / validation
drop policy if exists sel_hist on public.prospect_stage_history;
create policy sel_hist on public.prospect_stage_history for select using (true);

drop policy if exists sel_oppm on public.opportunity_milestones;
drop policy if exists mod_oppm on public.opportunity_milestones;
create policy sel_oppm on public.opportunity_milestones for select using (true);
create policy mod_oppm on public.opportunity_milestones
for all using (
  public.is_manager_or_admin()
  or exists (select 1 from public.prospects p where p.id = opportunity_milestones.prospect_id and p.owner_id = auth.uid())
) with check (
  public.is_manager_or_admin()
  or exists (select 1 from public.prospects p where p.id = opportunity_milestones.prospect_id and p.owner_id = auth.uid())
);

drop policy if exists sel_vsteps on public.validation_steps;
drop policy if exists mod_vsteps on public.validation_steps;
create policy sel_vsteps on public.validation_steps for select using (true);
create policy mod_vsteps on public.validation_steps
for all using (
  public.is_manager_or_admin()
  or exists (select 1 from public.prospects p where p.id = validation_steps.prospect_id and p.owner_id = auth.uid())
) with check (
  public.is_manager_or_admin()
  or exists (select 1 from public.prospects p where p.id = validation_steps.prospect_id and p.owner_id = auth.uid())
);
