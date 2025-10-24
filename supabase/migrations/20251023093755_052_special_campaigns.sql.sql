-- 052_special_campaigns
-- Ajoute la colonne special_key, garantit l'unicité et seed 2 campagnes spéciales.

---------------------------------------
-- 1) Colonne
---------------------------------------
alter table public.campaigns
  add column if not exists special_key text;

---------------------------------------
-- 2) Tenter d'annoter une campagne existante par nom (si déjà créée)
--    On ne met la clé spéciale que sur UNE ligne (la plus ancienne) pour éviter les doublons.
---------------------------------------

-- 'Ajout contact' -> ADD_CONTACT
with candidate as (
  select id
  from public.campaigns
  where special_key is null
    and lower(name) = 'ajout contact'
  order by created_at nulls last, id
  limit 1
)
update public.campaigns c
   set special_key = 'ADD_CONTACT'
  from candidate x
 where c.id = x.id;

-- 'Attribution manuelle' -> MANUAL_ASSIGN
with candidate as (
  select id
  from public.campaigns
  where special_key is null
    and lower(name) = 'attribution manuelle'
  order by created_at nulls last, id
  limit 1
)
update public.campaigns c
   set special_key = 'MANUAL_ASSIGN'
  from candidate x
 where c.id = x.id;

---------------------------------------
-- 3) Contrainte UNIQUE requise par ON CONFLICT
---------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'campaigns'
      and c.contype = 'u'
      and pg_get_constraintdef(c.oid) ilike '%(special_key)%'
  ) then
    alter table public.campaigns
      add constraint campaigns_special_key_uniq unique (special_key);
  end if;
end$$;

---------------------------------------
-- 4) Seed des 2 campagnes si absentes
-- NB: on ne fournit pas created_by (nullable) pour éviter de dépendre d'auth.uid() en migration.
---------------------------------------
insert into public.campaigns (name, status, special_key)
values
  ('Ajout contact',        'ACTIVE', 'ADD_CONTACT'),
  ('Attribution manuelle', 'ACTIVE', 'MANUAL_ASSIGN')
on conflict (special_key) do nothing;
