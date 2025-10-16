set search_path = public;

-- 0) Extension requise par les triggers de normalisation
create extension if not exists unaccent;

-- 1) Enum (si absente)
do $$
begin
  if not exists (select 1 from pg_type where typname = 'geo_zone_enum') then
    create type geo_zone_enum as enum ('IDF','PROVINCE');
  end if;
end$$;

-- 2) Unicité (plusieurs CP par ville acceptés) + index utiles
do $$
begin
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='geo_city_index_city_norm_postal_key') then
    create unique index geo_city_index_city_norm_postal_key
      on public.geo_city_index(city_norm, postal_code);
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

-- 3) Fonction d’upsert appelée par le loader IDF
create or replace function public.geo_city_index_merge()
returns void
language plpgsql
as $$
begin
  /*
    Table d'entrée attendue : public._geo_city_index_load (temporaire) avec :
      city_name text, postal_code text, insee_code text,
      dept_code text, region_name text, bucket text ('IDF'|'PROVINCE')
    NB: city_norm est recalculée par le trigger créé en 019.
  */
  insert into public.geo_city_index(city_name, postal_code, insee_code, dept_code, region_name, bucket)
  select l.city_name, l.postal_code, l.insee_code, l.dept_code, l.region_name, l.bucket::geo_zone_enum
  from public._geo_city_index_load l
  on conflict (city_norm, postal_code) do update
  set city_name   = excluded.city_name,
      insee_code  = excluded.insee_code,
      dept_code   = excluded.dept_code,
      region_name = excluded.region_name,
      bucket      = excluded.bucket;
end
$$;
