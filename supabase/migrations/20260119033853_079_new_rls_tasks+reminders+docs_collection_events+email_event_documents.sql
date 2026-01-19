-- Enable RLS on previously unrestricted tables
alter table public.prospect_tasks enable row level security;
alter table public.prospect_reminders enable row level security;
alter table public.docs_collection_events enable row level security;
alter table public.email_event_documents enable row level security;

-- ----------------------------
-- prospect_tasks
-- ----------------------------
drop policy if exists "prospect_tasks_select_auth" on public.prospect_tasks;
drop policy if exists "prospect_tasks_insert_auth" on public.prospect_tasks;
drop policy if exists "prospect_tasks_update_auth" on public.prospect_tasks;
drop policy if exists "prospect_tasks_delete_auth" on public.prospect_tasks;

create policy "prospect_tasks_select_auth"
on public.prospect_tasks
for select
to authenticated
using (true);

create policy "prospect_tasks_insert_auth"
on public.prospect_tasks
for insert
to authenticated
with check (true);

create policy "prospect_tasks_update_auth"
on public.prospect_tasks
for update
to authenticated
using (true)
with check (true);

create policy "prospect_tasks_delete_auth"
on public.prospect_tasks
for delete
to authenticated
using (true);

-- ----------------------------
-- prospect_reminders
-- ----------------------------
drop policy if exists "prospect_reminders_select_auth" on public.prospect_reminders;
drop policy if exists "prospect_reminders_insert_auth" on public.prospect_reminders;
drop policy if exists "prospect_reminders_update_auth" on public.prospect_reminders;
drop policy if exists "prospect_reminders_delete_auth" on public.prospect_reminders;

create policy "prospect_reminders_select_auth"
on public.prospect_reminders
for select
to authenticated
using (true);

create policy "prospect_reminders_insert_auth"
on public.prospect_reminders
for insert
to authenticated
with check (true);

create policy "prospect_reminders_update_auth"
on public.prospect_reminders
for update
to authenticated
using (true)
with check (true);

create policy "prospect_reminders_delete_auth"
on public.prospect_reminders
for delete
to authenticated
using (true);

-- ----------------------------
-- docs_collection_events
-- ----------------------------
drop policy if exists "docs_collection_events_select_auth" on public.docs_collection_events;
drop policy if exists "docs_collection_events_insert_auth" on public.docs_collection_events;
drop policy if exists "docs_collection_events_update_auth" on public.docs_collection_events;
drop policy if exists "docs_collection_events_delete_auth" on public.docs_collection_events;

create policy "docs_collection_events_select_auth"
on public.docs_collection_events
for select
to authenticated
using (true);

create policy "docs_collection_events_insert_auth"
on public.docs_collection_events
for insert
to authenticated
with check (true);

create policy "docs_collection_events_update_auth"
on public.docs_collection_events
for update
to authenticated
using (true)
with check (true);

create policy "docs_collection_events_delete_auth"
on public.docs_collection_events
for delete
to authenticated
using (true);

-- ----------------------------
-- email_event_documents
-- ----------------------------
drop policy if exists "email_event_documents_select_auth" on public.email_event_documents;
drop policy if exists "email_event_documents_insert_auth" on public.email_event_documents;
drop policy if exists "email_event_documents_update_auth" on public.email_event_documents;
drop policy if exists "email_event_documents_delete_auth" on public.email_event_documents;

create policy "email_event_documents_select_auth"
on public.email_event_documents
for select
to authenticated
using (true);

create policy "email_event_documents_insert_auth"
on public.email_event_documents
for insert
to authenticated
with check (true);

create policy "email_event_documents_update_auth"
on public.email_event_documents
for update
to authenticated
using (true)
with check (true);

create policy "email_event_documents_delete_auth"
on public.email_event_documents
for delete
to authenticated
using (true);