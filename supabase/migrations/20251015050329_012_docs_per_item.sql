do $$ begin
  create type doc_item_status as enum ('REQUESTED','PENDING','INCOMPLETE','RECEIVED','NOT_REQUIRED');
exception when duplicate_object then null; end $$;

alter table public.documents
  add column if not exists requested_at      timestamptz,
  add column if not exists received_at       timestamptz,
  add column if not exists last_reminder_at  timestamptz,
  add column if not exists reminder_count    int default 0;

-- Harmonisation douce: convertir documents.status -> doc_item_status si possible
do $$ begin
  alter table public.documents
    alter column status type doc_item_status
    using case upper(coalesce(status::text,'')) 
      when 'REQUESTED' then 'REQUESTED'::doc_item_status
      when 'PENDING' then 'PENDING'::doc_item_status
      when 'INCOMPLETE' then 'INCOMPLETE'::doc_item_status
      when 'RECEIVED' then 'RECEIVED'::doc_item_status
      when 'NOT_REQUIRED' then 'NOT_REQUIRED'::doc_item_status
      else null end;
exception when others then null; end $$;

create index if not exists idx_documents_prospect on public.documents (prospect_id);
create index if not exists idx_documents_status   on public.documents (status);
