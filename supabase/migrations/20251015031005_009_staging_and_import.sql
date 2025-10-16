create table if not exists public.staging_raw_prospects (
  batch_label       text,
  first_name        text,
  last_name         text,
  phone             text,
  email             text,
  civility          text,
  birth_date        text,
  address1          text,
  address2          text,
  postal_code       text,
  city              text,
  net_salary        text,
  co_borrower       text,
  co_net_salary     text,
  comments          text,
  annexes           text,
  annexes_private   text,
  source            text
);

create or replace function public.normalize_phone_fr(raw text)
returns text language plpgsql immutable as $$
declare p text;
begin
  if raw is null then return null; end if;
  p := regexp_replace(raw, '\D', '', 'g');
  if p ~ '^0\d{9}$' then
    return '+33' || substr(p,2);
  elseif p ~ '^33\d{9}$' then
    return '+' || p;
  elseif p ~ '^\+?\d{8,15}$' then
    return case when left(p,1)='+' then p else '+'||p end;
  else
    return null;
  end if;
end $$;

create or replace function public.normalize_cp(raw text)
returns text language sql immutable as $$
  select case when raw ~ '^\d{5}$' then raw else null end
$$;

create or replace function public.normalize_email(raw text)
returns text language sql immutable as $$
  select case
    when raw ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then lower(raw)
    else null
  end
$$;

create or replace function public.parse_bool(raw text)
returns boolean language sql immutable as $$
  select case
    when raw is null then null
    when lower(raw) in ('true','vrai','1','yes','oui') then true
    when lower(raw) in ('false','faux','0','no','non','') then false
    else null
  end
$$;

create or replace function public.import_prospects_from_staging(
  p_batch_label text default null,
  p_obtained_on date default current_date,
  p_source source_enum default null
)
returns table(list_batch_id bigint, inserted_count int)
language plpgsql
security definer
set search_path = public
as $$
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
      public.normalize_phone_fr(phone)                       as phone_norm,
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
end $$;
