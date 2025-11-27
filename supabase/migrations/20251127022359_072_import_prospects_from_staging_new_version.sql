-- 2) Nouvelle version SECURISEE de import_prospects_from_staging
--    Seule modification : birth_norm = public.parse_birth_date(birth_date)

create or replace function public.import_prospects_from_staging(
  p_batch_label text DEFAULT NULL::text,
  p_obtained_on date DEFAULT CURRENT_DATE,
  p_source source_enum DEFAULT NULL::source_enum
)
returns table(list_batch_id bigint, inserted_count integer)
language plpgsql
security definer
set search_path to public
AS $function$
declare
  v_batch_id bigint;
begin
  -- Crée ou récupère le batch
  insert into public.list_batches(label, obtained_on, source, created_by)
  values (p_batch_label, p_obtained_on, p_source, auth.uid())
  on conflict(label) do update
    set obtained_on = excluded.obtained_on,
        source      = excluded.source
  returning id into v_batch_id;

  with src as (
    select *
    from public.staging_raw_prospects
    where batch_label = p_batch_label
  ),
  filtered as (
    select
      first_name,
      last_name,
      email,
      normalize_email(email) as email_norm,
      phone,
      normalize_fr_phone(phone) as phone_e164,
      -- CHANGEMENT ICI ⬇⬇⬇
      public.parse_birth_date(birth_date) as birth_norm,
      civility,
      address1,
      address2,
      postal_code,
      city,
      net_salary,
      co_borrower,
      co_net_salary,
      comments,
      annexes,
      annexes_private,
      source,
      employment_status,
      housing_status,
      city_norm
    from src
  ),
  dedup as (
    select *
    from filtered
    where phone_e164 is not null
       or email_norm is not null
  )
  insert into public.prospects(
    list_batch_id,
    first_name,
    last_name,
    email,
    phone_e164,
    birth_date,
    civility,
    address1,
    address2,
    postal_code,
    city,
    net_salary,
    has_co_borrower,
    co_net_salary,
    comments,
    annexes,
    annexes_private,
    source,
    employment_status,
    housing_status,
    geo_zone,
    created_at
  )
  select
    v_batch_id,
    first_name,
    last_name,
    email_norm,
    phone_e164,
    birth_norm,
    normalize_civility(civility),
    address1,
    address2,
    postal_code,
    city,
    parse_numeric_eur(net_salary),
    parse_bool(co_borrower),
    parse_numeric_eur(co_net_salary),
    comments,
    annexes,
    parse_bool(annexes_private),
    source::source_enum,
    employment_status::employment_status_enum,
    housing_status::housing_status_enum,
    compute_geo_zone(postal_code),
    now()
  from dedup
  returning list_batch_id, count(*) into list_batch_id, inserted_count;

end;
$function$;