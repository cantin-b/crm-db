-- Fonction de normalisation
create or replace function public.trg_documents_enforce_required_status()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- 1) Si le statut demandé est NOT_REQUIRED, on met tout en "non requis"
  if new.status::text = 'NOT_REQUIRED' then
    new.required         := false;
    new.status           := 'NOT_REQUIRED';
    new.requested_at     := null;
    new.received_at      := null;
    new.last_reminder_at := null;
    new.reminder_count   := 0;
    -- Optionnel, si tu veux purger le fichier quand non requis :
    -- new.file_path     := null;
    return new;
  end if;

  -- 2) Si "required" est décoché, on force l'état de base "non requis"
  if coalesce(new.required, false) = false then
    new.required         := false;
    new.status           := 'NOT_REQUIRED';
    new.requested_at     := null;
    new.received_at      := null;
    new.last_reminder_at := null;
    new.reminder_count   := 0;
    -- Optionnel :
    -- new.file_path     := null;
    return new;
  end if;

  -- 3) Ici, le document est requis (ou on vient d'envoyer un statut ≠ NOT_REQUIRED)
  --    → on s'assure que required=true et que le statut est au moins PENDING
  new.required := true;

  if new.status is null or new.status::text = '' or new.status::text = 'NOT_REQUIRED' then
    new.status := 'PENDING';
  end if;

  -- (Optionnel) si un received_at est fourni, tu peux imposer RECEIVED
  -- if new.received_at is not null then
  --   new.status := 'RECEIVED';
  -- end if;

  return new;
end
$$;

-- Trigger BEFORE sur insert/update
drop trigger if exists trg_documents_enforce_required_status on public.documents;
create trigger trg_documents_enforce_required_status
before insert or update on public.documents
for each row
execute function public.trg_documents_enforce_required_status();