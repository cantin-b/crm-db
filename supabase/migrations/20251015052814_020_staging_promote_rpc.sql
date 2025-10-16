set search_path = public;

-- Extensions
create extension if not exists unaccent;

-- 1) Helpers -------------------------------------------------------------

-- 1.a) normalisation téléphone FR -> E.164 (+33XXXXXXXXX)
create or replace function public.normalize_fr_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare p text;
begin
  if raw is null or btrim(raw)='' then return null; end if;
  -- supprime espaces puis tout sauf chiffres et '+'
  p := regexp_replace(raw, '\s+', '', 'g');
  p := regexp_replace(p, '[^0-9+]', '', 'g');

  if p ~ '^\+33\d{9}$' then return p; end if;       -- déjà E.164 FR
  if p ~ '^33\d{9}$' then return '+'||p; end if;    -- 33XXXXXXXXX
  if p ~ '^0\d{9}$' then return '+33'||substr(p,2); end if;  -- 0XXXXXXXXX
  if p ~ '^\d{9}$' then return '+33'||p; end if;    -- 9 chiffres « nus »

  return null;
end$$;

-- 1.b) parser numéraire souple (retourne NULL si non castable)
create or replace function public.parse_numeric_eur(s text)
returns numeric
language plpgsql
immutable
as $$
declare t text; n numeric;
begin
  if s is null then return null; end if;
  -- garde chiffres, ., , et -
  t := regexp_replace(s, '[^0-9,.\-]', '', 'g');

  -- si virgule ET point présents, on essaie de deviner le séparateur décimal
  if position(',' in t) > 0 and position('.' in t) > 0 then
    if right(t,1) = ',' then
      t := replace(replace(t,'.',''),',','.');
    elsif right(t,1) = '.' then
      t := replace(t,',','');
    else
      t := replace(replace(t,'.',''),',','.');
    end if;
  else
    t := replace(t,',','.');
  end if;

  begin
    n := t::numeric;
  exception when others then
    return null;
  end;
  return n;
end$$;

-- 1.c) parser booléen souple (fr/en) : 1/0, oui/non, true/false
create or replace function public.parse_bool_generic(s text)
returns boolean
language sql
immutable
as $$
  select case
    when s is null then null
    when lower(trim(s)) in ('1','true','t','yes','y','oui','vrai','x') then true
    when lower(trim(s)) in ('0','false','f','no','n','non') then false
    else null
  end;
$$;

-- 1.d) normalisation ville déjà fournie (019) ; on la garde au cas où
create or replace function public.normalize_city_text(s text)
returns text
language sql
stable
as $$
  select lower(regexp_replace(unaccent(coalesce(s,'')),'[^a-z0-9]','','g'));
$$;

-- 1.e) compute_geo_zone(postal_code, city_norm) -> geo_zone_enum
--  Règle V1 :
--   - si CP valide (5 chiffres) : dept in (75,77,78,91,92,93,94,95) = 'IDF', sinon 'PROVINCE'
--   - sinon si city_norm match dans geo_city_index : renvoie bucket (si présent)
--   - sinon NULL (filtre "Non spécifié" côté UI)
create or replace function public.compute_geo_zone(postal_code text, city_norm text)
returns public.geo_zone_enum
language plpgsql
stable
as $$
declare dept text; z public.geo_zone_enum;
begin
  if postal_code ~ '^\d{5}$' then
    dept := substr(postal_code,1,2);
    if dept in ('75','77','78','91','92','93','94','95') then
      return 'IDF'::public.geo_zone_enum;
    else
      return 'PROVINCE'::public.geo_zone_enum;
    end if;
  end if;

  if city_norm is not null and city_norm <> '' then
    select g.bucket into z
      from public.geo_city_index g
     where g.city_norm = city_norm
     order by g.id
     limit 1;
    if z is not null then return z; end if;
  end if;

  return null;
end$$;

-- 1.f) s'assure qu'un lot (list_batch) existe et retourne son id
create or replace function public.ensure_list_batch(p_label text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare bid bigint;
begin
  select id into bid from public.list_batches where label = p_label limit 1;
  if bid is null then
    insert into public.list_batches(label, obtained_on)
    values (p_label, now()::date)
    returning id into bid;
  end if;
  return bid;
end$$;

-- 2) RPC : promotion d'un batch depuis staging vers prospects --------------
--  V1 simple :
--   - prend s.batch_label = p_batch_label
--   - prépare/normalise : email, phone_e164, salaires, booleans, geo_zone
--   - insère dans prospects (stage par défaut table; on ne le force pas ici)
--   - retourne (inserted_count, batch_id)
create or replace function public.staging_promote_batch(p_batch_label text)
returns table(inserted_count bigint, batch_id bigint)
language plpgsql
security definer
set search_path = public
as $$
declare v_batch_id bigint;
begin
  if coalesce(trim(p_batch_label),'') = '' then
    raise exception 'batch_label must not be empty';
  end if;

  v_batch_id := public.ensure_list_batch(p_batch_label);

  insert into public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    birth_date,            -- V1: on ne parse pas, on laisse NULL
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status, geo_zone
  )
  select
    v_batch_id,
    nullif(lower(trim(s.first_name)),'') as first_name,
    nullif(lower(trim(s.last_name)),'')  as last_name,
    nullif(s.civility,'')                as civility,
    null::date                           as birth_date,
    nullif(s.address1,'')                as address1,
    nullif(s.address2,'')                as address2,
    nullif(s.postal_code,'')             as postal_code,
    nullif(s.city,'')                    as city,
    nullif(lower(trim(s.email)),'')      as email,
    public.normalize_fr_phone(s.phone)   as phone_e164,
    public.parse_numeric_eur(s.net_salary)      as net_salary,
    public.parse_bool_generic(s.co_borrower)    as co_borrower,
    public.parse_numeric_eur(s.co_net_salary)   as co_net_salary,
    nullif(s.comments,'')                as comments,
    nullif(s.annexes,'')                 as annexes,
    coalesce(public.parse_bool_generic(s.annexes_private), false) as annexes_private,
    s.employment_status,
    s.housing_status,
    public.compute_geo_zone(s.postal_code, s.city_norm)
  from public.staging_raw_prospects s
  where s.batch_label = p_batch_label;

  get diagnostics inserted_count = row_count;
  batch_id := v_batch_id;
  return next;
end$$;

-- (Optionnel) droits d'exécution pour l'app
do $$
begin
  -- adapte selon tes rôles Supabase
  perform 1;
exception when others then
  null;
end$$;
