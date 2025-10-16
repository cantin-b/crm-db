set search_path = public;

-- 0) Extension utile
create extension if not exists unaccent;

-- 1) Aligner staging_raw_prospects (ajouts manquants pour V1)
do $$
begin
  -- employment_status / housing_status (enums déjà existants côté prospects)
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='staging_raw_prospects' and column_name='employment_status'
  ) then
    alter table public.staging_raw_prospects
      add column employment_status public.employment_status_enum;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='staging_raw_prospects' and column_name='housing_status'
  ) then
    alter table public.staging_raw_prospects
      add column housing_status public.housing_status_enum;
  end if;

  -- city_norm (colonne "classique", pas générée)
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='staging_raw_prospects' and column_name='city_norm'
  ) then
    alter table public.staging_raw_prospects
      add column city_norm text;
  end if;
end$$;

-- 2) Fonction de normalisation (STABLE)
create or replace function public.normalize_city_text(s text)
returns text
language sql
stable
as $$
  select lower(regexp_replace(unaccent(coalesce(s,'')),'[^a-z0-9]','','g'));
$$;

-- 3) Trigger function commune
create or replace function public.trg_set_city_norm()
returns trigger
language plpgsql
as $$
begin
  new.city_norm := public.normalize_city_text(new.city);
  return new;
end$$;

-- 4) Trigger sur staging_raw_prospects
drop trigger if exists set_city_norm_staging on public.staging_raw_prospects;
create trigger set_city_norm_staging
before insert or update of city on public.staging_raw_prospects
for each row execute function public.trg_set_city_norm();

-- 5) Squelette geo_city_index (pour matching local ville/CP/INSEE)
create table if not exists public.geo_city_index (
  id           bigserial primary key,
  insee        text        not null,
  postal_code  text        not null,
  city_name    text        not null,
  dept_code    text        not null,
  region_name  text,
  bucket       public.geo_zone_enum,  -- 'IDF' | 'PROVINCE' | null (DROMCOM plus tard)
  city_norm    text
);

-- 5b) Trigger city_norm sur geo_city_index
drop trigger if exists set_city_norm_geo on public.geo_city_index;
create trigger set_city_norm_geo
before insert or update of city_name on public.geo_city_index
for each row execute function public.trg_set_city_norm();

-- 6) Index utiles
create index if not exists idx_geo_city_index_city_norm   on public.geo_city_index using btree (city_norm);
create index if not exists idx_geo_city_index_postal_code on public.geo_city_index (postal_code);
create index if not exists idx_geo_city_index_insee       on public.geo_city_index (insee);
