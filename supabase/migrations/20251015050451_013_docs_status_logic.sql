-- Recalcule le docs_status du prospect d'après ses lignes de documents
create or replace function public.recompute_docs_status(p_prospect_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_any_req boolean;        -- au moins un doc demandé (≠ NOT_REQUIRED)
  v_any_incomplete boolean; -- présence d’au moins un INCOMPLETE
  v_all_received boolean;   -- tous les "demandés" sont RECEIVED
  v_first_received timestamptz;
  v_all_received_at timestamptz;
  v_any_requested_at timestamptz;
begin
  -- agrégation d'état
  select
    exists(select 1 from documents d where d.prospect_id = p_prospect_id and d.status is distinct from 'NOT_REQUIRED'),
    exists(select 1 from documents d where d.prospect_id = p_prospect_id and d.status = 'INCOMPLETE'),
    coalesce(bool_and(d.status = 'RECEIVED') filter (where d.status is distinct from 'NOT_REQUIRED'), false)
  into v_any_req, v_any_incomplete, v_all_received
  from documents d where d.prospect_id = p_prospect_id;

  -- dates pour milestones
  select min(received_at), max(received_at)
    into v_first_received, v_all_received_at
  from documents d
  where d.prospect_id = p_prospect_id and d.status = 'RECEIVED';

  select min(requested_at)
    into v_any_requested_at
  from documents d
  where d.prospect_id = p_prospect_id and d.status is distinct from 'NOT_REQUIRED';

  -- règle vers prospects.docs_status
  update prospects p
     set docs_status =
       case
         when not v_any_req then null                              -- "À initier" (champ vide)
         when v_any_incomplete then 'INCOMPLETE'::docs_status_enum
         when v_all_received   then 'COMPLETE'::docs_status_enum
         else 'PENDING'::docs_status_enum
       end
   where p.id = p_prospect_id;

  -- préparation milestone row
  insert into opportunity_milestones (prospect_id) values (p_prospect_id)
  on conflict (prospect_id) do nothing;

  -- mise à jour milestone dates
  update opportunity_milestones m
     set docs_requested_at      = coalesce(m.docs_requested_at, v_any_requested_at),
         docs_first_received_at = coalesce(m.docs_first_received_at, v_first_received),
         docs_completed_at      = case when v_all_received
                                        then coalesce(m.docs_completed_at, coalesce(v_all_received_at, now()))
                                        else m.docs_completed_at end
   where m.prospect_id = p_prospect_id;
end $$;

-- Trigger d’auto-recalcul sur documents
create or replace function public.trg_documents_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare pid uuid;
begin
  pid := coalesce(new.prospect_id, old.prospect_id);
  perform public.recompute_docs_status(pid);
  return coalesce(new, old);
end $$;

drop trigger if exists documents_after_change on public.documents;
create trigger documents_after_change
after insert or update or delete on public.documents
for each row execute function public.trg_documents_after_change();

-- RPC: démarrer la collecte (pose docs_requested_at et bascule NULL -> REQUESTED)
create or replace function public.start_docs_collection(p_prospect_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into opportunity_milestones (prospect_id, docs_requested_at)
  values (p_prospect_id, now())
  on conflict (prospect_id) do update
    set docs_requested_at = coalesce(opportunity_milestones.docs_requested_at, excluded.docs_requested_at);

  update documents
     set status='REQUESTED', requested_at=coalesce(requested_at, now())
   where prospect_id = p_prospect_id and status is null;

  perform public.recompute_docs_status(p_prospect_id);
end $$;

-- RPC: relance opportunité
create or replace function public.opportunity_record_reminder(p_prospect_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into opportunity_milestones (prospect_id, last_reminder_at, reminder_count)
  values (p_prospect_id, now(), 1)
  on conflict (prospect_id) do update
    set last_reminder_at = now(),
        reminder_count   = coalesce(opportunity_milestones.reminder_count,0) + 1;
end $$;

-- RPC: marquer devis envoyé
create or replace function public.opportunity_mark_quote_sent(p_prospect_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into opportunity_milestones (prospect_id, quote_sent_at)
  values (p_prospect_id, now())
  on conflict (prospect_id) do update
    set quote_sent_at = coalesce(opportunity_milestones.quote_sent_at, now())
$$;

-- RPC: transitions de stage
create or replace function public.prospect_to_opportunity(p_prospect_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update prospects
     set stage = 'OPPORTUNITY', stage_changed_at = now()
   where id = p_prospect_id;
  if p_note is not null then
    update prospects set comments = coalesce(comments,'') || E'\n— ' || p_note where id = p_prospect_id;
  end if;
end $$;

create or replace function public.prospect_to_validation(p_prospect_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update prospects
     set stage = 'VALIDATION', stage_changed_at = now()
   where id = p_prospect_id;
  if p_note is not null then
    update prospects set comments = coalesce(comments,'') || E'\n— ' || p_note where id = p_prospect_id;
  end if;
end $$;

create or replace function public.prospect_mark_refused(p_prospect_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update prospects
     set stage = 'PHONING',
         phoning_disposition = 'REFUS',
         stage_changed_at = now(),
         ko_reason = p_reason
   where id = p_prospect_id;

  if p_reason is not null then
    update prospects set comments = coalesce(comments,'') || E'\n— Refus: ' || p_reason where id = p_prospect_id;
  end if;
end $$;

-- Garde-fou: empêcher de remettre phoning_disposition à NULL
create or replace function public.prevent_phoning_disposition_reset()
returns trigger
language plpgsql
as $$
begin
  if old.phoning_disposition is not null and new.phoning_disposition is null then
    raise exception 'Impossible de remettre le statut phoning à NULL (Nouveau lead) une fois défini.';
  end if;
  return new;
end $$;

drop trigger if exists trg_no_reset_phoning_disposition on public.prospects;
create trigger trg_no_reset_phoning_disposition
before update on public.prospects
for each row when (old.phoning_disposition is distinct from new.phoning_disposition)
execute function public.prevent_phoning_disposition_reset();
