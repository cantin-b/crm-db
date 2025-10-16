set search_path=public;

-- Sécurité: extension pour la normalisation
create extension if not exists unaccent;

-- Enum zone si absente
do $$
begin
  if not exists (select 1 from pg_type where typname='geo_zone_enum') then
    create type geo_zone_enum as enum ('IDF','PROVINCE');
  end if;
end$$;

-- Table présente ? Si non, on la crée avec le bon schéma minimal
do $$
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='geo_city_index') then
    create table public.geo_city_index(
      city_name   text,
      postal_code text,
      insee_code  text,
      dept_code   text,
      region_name text,
      bucket      geo_zone_enum,
      city_norm   text
    );
  end if;
end$$;

-- Renommer "insee" -> "insee_code" si nécessaire
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='geo_city_index' and column_name='insee'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='geo_city_index' and column_name='insee_code'
  ) then
    alter table public.geo_city_index rename column insee to insee_code;
  end if;
end$$;

-- Ajouter les colonnes manquantes
alter table public.geo_city_index
  add column if not exists city_name   text,
  add column if not exists postal_code text,
  add column if not exists insee_code  text,
  add column if not exists dept_code   text,
  add column if not exists region_name text,
  add column if not exists bucket      geo_zone_enum,
  add column if not exists city_norm   text;

-- Fonction/trigger de normalisation city_norm (depuis city_name)
create or replace function public._set_city_norm_from_name()
returns trigger language plpgsql as $$
begin
  new.city_norm := lower(regexp_replace(unaccent(coalesce(new.city_name,'')),'[^a-z0-9]','','g'));
  return new;
end$$;

do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema='public' and table_name='geo_city_index') then
    if exists (select 1 from information_schema.triggers
               where event_object_schema='public' and event_object_table='geo_city_index'
                 and trigger_name='set_city_norm_geo') then
      drop trigger set_city_norm_geo on public.geo_city_index;
    end if;
    create trigger set_city_norm_geo
      before insert or update of city_name
      on public.geo_city_index
      for each row
      execute procedure public._set_city_norm_from_name();
  end if;
end$$;

-- Index (idempotents)
do $$
begin
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='geo_city_index_city_norm_postal_key') then
    create unique index geo_city_index_city_norm_postal_key on public.geo_city_index(city_norm, postal_code);
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='geo_city_index_city_norm_idx') then
    create index geo_city_index_city_norm_idx on public.geo_city_index(city_norm);
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='geo_city_index_dept_idx') then
    create index geo_city_index_dept_idx on public.geo_city_index(dept_code);
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='geo_city_index_bucket_idx') then
    create index geo_city_index_bucket_idx on public.geo_city_index(bucket);
  end if;
end$$;
