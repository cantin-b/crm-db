-- 041_normalize_fr_phone.sql
-- Normalize French phone numbers and enforce +33 E.164 storage
-- Includes trigger + import function updates + backfill

-- 1) Unify and reinforce normalization (handles also 0033)
create or replace function public.normalize_fr_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare p text;
begin
  if raw is null or btrim(raw) = '' then
    return null;
  end if;

  -- remove spaces and keep only digits and '+'
  p := regexp_replace(raw, '\s+', '', 'g');
  p := regexp_replace(p, '[^0-9+]', '', 'g');

  -- tolerate 0033 -> +33
  if p ~ '^00' then
    p := regexp_replace(p, '^00', '+');
  end if;

  -- canonical French cases
  if p ~ '^\+33\d{9}$' then return p; end if;           -- already E.164 FR
  if p ~ '^33\d{9}$'  then return '+'||p; end if;       -- 33XXXXXXXXX
  if p ~ '^0\d{9}$'   then return '+33'||substr(p,2); end if;  -- 0XXXXXXXXX
  if p ~ '^\d{9}$'    then return '+33'||p; end if;     -- 9 digits bare

  -- fallback: other E.164 +country numbers
  if p ~ '^\+\d{8,15}$' then return p; end if;

  return null;
end
$$;


-- 2) Enforce normalization on INSERT/UPDATE
create or replace function public.trg_prospects_normalize_phone()
returns trigger
language plpgsql
as $$
begin
  if new.phone_e164 is not null then
    new.phone_e164 := public.normalize_fr_phone(new.phone_e164);
  end if;
  return new;
end
$$;

drop trigger if exists tgn_prospects_normalize_phone on public.prospects;
create trigger tgn_prospects_normalize_phone
before insert or update of phone_e164
on public.prospects
for each row
execute function public.trg_prospects_normalize_phone();


-- 3) Update import_prospects_from_staging to use normalize_fr_phone
create or replace function public.import_prospects_from_staging(
  p_batch_label text default null,
  p_obtained_on date default current_date,
  p_source public.source_enum default null
)
returns table(list_batch_id bigint, inserted_count integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_batch_id bigint;
begin
  insert into public.list_batches(label, obtained_on, source, size_hint)
  values (
    coalesce(nullif(p_batch_label,''), 'IMPORT_'||to_char(now(),'YYYYMMDD-HH24MISS')),
    p_obtained_on,
    p_source,
    (select count(*) from public.staging_raw_prospects)
  ) returning id into v_batch_id;

  with src as (
    select
      nullif(trim(first_name),'')                            as first_name,
      nullif(trim(last_name),'')                             as last_name,
      public.normalize_email(email)                          as email_norm,
      public.normalize_fr_phone(phone)                       as phone_norm, -- unified here
      nullif(upper(trim(civility)),'')                       as civility_norm,
      to_date(nullif(birth_date,''),'YYYY-MM-DD')            as birth_norm,
      nullif(trim(address1),'')                              as address1_norm,
      nullif(trim(address2),'')                              as address2_norm,
      public.normalize_cp(postal_code)                       as postal_code_norm,
      nullif(trim(city),'')                                  as city_norm,
      nullif(regexp_replace(net_salary,'[^\d.,]','','g'),'')::numeric    as net_salary_norm,
      public.parse_bool(co_borrower)                         as co_borrower_norm,
      nullif(regexp_replace(co_net_salary,'[^\d.,]','','g'),'')::numeric as co_net_salary_norm,
      nullif(trim(comments),'')                              as comments_norm,
      nullif(trim(annexes),'')                               as annexes_norm,
      coalesce(public.parse_bool(annexes_private), false)    as annexes_private_norm,
      case upper(trim(source))
        when 'PARRAINAGE'   then 'PARRAINAGE'::source_enum
        when 'LEAD'         then 'LEAD'::source_enum
        when 'LISTE_ACHETEE' then 'LISTE_ACHETEE'::source_enum
        else null end                                         as source_enum_norm
    from public.staging_raw_prospects
  ),
  filtered as (
    select * from src
    where first_name is not null
      and last_name  is not null
      and (phone_norm is not null or email_norm is not null)
  ),
  dedup as (
    select f.*
      from filtered f
     where not exists (
       select 1 from public.prospects p
        where (f.phone_norm is not null and p.phone_e164 = f.phone_norm)
           or (f.email_norm is not null and p.email      = f.email_norm)
     )
  )
  insert into public.prospects (
    list_batch_id, first_name, last_name, email, phone_e164,
    civility, birth_date,
    address1, address2, postal_code, city,
    net_salary, co_borrower, co_net_salary,
    comments, annexes, annexes_private, source, stage
  )
  select
    v_batch_id,
    first_name, last_name, email_norm, phone_norm,
    civility_norm, birth_norm,
    address1_norm, address2_norm, postal_code_norm, city_norm,
    net_salary_norm, co_borrower_norm, co_net_salary_norm,
    comments_norm, annexes_norm, annexes_private_norm,
    source_enum_norm, 'PHONING'::stage_enum
  from dedup;

  get diagnostics inserted_count = row_count;
  return query select v_batch_id, inserted_count;
end
$function$;


-- 4) Update staging_promote_batch to normalize phone before insert
create or replace function public.staging_promote_batch(p_batch_label text)
returns table(batch_id bigint, inserted_count integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_batch_id bigint; v_cnt int;
begin
  insert into public.list_batches(label) values (p_batch_label) returning id into v_batch_id;

  insert into public.prospects(
    list_batch_id,
    first_name, last_name, civility,
    address1, address2, postal_code, city,
    email, phone_e164,
    net_salary, co_borrower, co_net_salary,
    comments, annexes, annexes_private,
    employment_status, housing_status,
    geo_zone
  )
  select
    v_batch_id,
    s.first_name, s.last_name, s.civility,
    s.address1, s.address2, s.postal_code, s.city,
    nullif(lower(trim(s.email)), ''),
    public.normalize_fr_phone(s.phone),  -- normalize here
    nullif(replace(regexp_replace(coalesce(s.net_salary,''),'[^0-9.,\-]','','g'),',','.'),'')::numeric,
    case
      when lower(coalesce(s.co_borrower,'')) in ('1','true','t','yes','y','oui','vrai','x') then true
      when lower(coalesce(s.co_borrower,'')) in ('0','false','f','no','n','non') then false
      else null
    end,
    nullif(replace(regexp_replace(coalesce(s.co_net_salary,''),'[^0-9.,\-]','','g'),',','.'),'')::numeric,
    s.comments,
    s.annexes,
    coalesce(
      case
        when lower(coalesce(s.annexes_private,'')) in ('1','true','t','yes','y','oui','vrai','x') then true
        when lower(coalesce(s.annexes_private,'')) in ('0','false','f','no','n','non') then false
        else null
      end, false
    ),
    case
      when s.employment_status in ('FONCTIONNAIRE','INDEPENDANT','SALA_PRIVE','RETRAITE')
        then s.employment_status::public.employment_status_enum
      else null
    end,
    case
      when s.housing_status in ('LOCATAIRE','PROPRIETAIRE','HEBERGE')
        then s.housing_status::public.housing_status_enum
      else null
    end,
    (
      case
        when left(regexp_replace(coalesce(s.postal_code,''),'[^0-9]','','g'),2) in ('75','77','78','91','92','93','94','95') then 'IDF'
        when length(left(regexp_replace(coalesce(s.postal_code,''),'[^0-9]','','g'),2)) = 2 then 'PROVINCE'
        when gl.bucket is not null then gl.bucket::text
        else null
      end
    )::public.geo_zone_enum
  from public.staging_raw_prospects s
  left join lateral (
    select g.bucket
    from public.geo_city_index g
    where g.city_norm = s.city_norm
      and (s.postal_code is null or g.postal_code = s.postal_code)
    order by (g.postal_code = s.postal_code) desc nulls last
    limit 1
  ) gl on true
  where s.batch_label = p_batch_label;

  get diagnostics v_cnt = row_count;
  return query select v_batch_id, v_cnt;
end
$function$;


-- 5) Backfill existing data
update public.prospects
   set phone_e164 = public.normalize_fr_phone(phone_e164)
 where phone_e164 is not null and btrim(phone_e164) <> '';


-- 6) Optional constraint for final validation
alter table if exists public.prospects
  drop constraint if exists phone_e164_e164_fr;
alter table public.prospects
  add constraint phone_e164_e164_fr
  check (phone_e164 is null or phone_e164 ~ '^\+33\d{9}$');
