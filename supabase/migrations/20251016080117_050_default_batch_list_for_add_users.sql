-- 050_default_manual_list.sql

-- Unicité logique du label (insensible à la casse)
do $$
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and indexname='ux_list_batches_label_ci'
  ) then
    create unique index ux_list_batches_label_ci
      on public.list_batches (lower(label));
  end if;
end$$;

-- Créer la liste "Saisie manuelle" si absente
insert into public.list_batches(label, source, obtained_on, is_public)
select 'Saisie manuelle', 'LEAD', current_date, true
where not exists (
  select 1 from public.list_batches where lower(label) = lower('Saisie manuelle')
);

-- (optionnel) autoriser la lecture à tous les utilisateurs authentifiés
-- create policy if not exists "list_batches select" on public.list_batches
-- for select to authenticated using (true);

-- (optionnel) recharger le cache PostgREST si tu utilises self-host
-- notify pgrst, 'reload schema';
