set search_path = public;

-- 1) Drop toutes les surcharges existantes (peu importe le type de retour)
do $$
declare r record;
begin
  for r in
    select n.nspname, p.proname, oidvectortypes(p.proargtypes) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'staging_promote_batch'
  loop
    execute format('drop function if exists %I.%I(%s);', r.nspname, r.proname, r.args);
  end loop;
end
$$;

-- 2) Recréer la RPC (signature stable)
create function public.staging_promote_batch(p_batch_label text)
returns table(batch_id bigint, inserted_count integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id bigint;
  v_cnt int;
begin
  -- a) créer un lot pour ce label
  insert into public.list_batches(label)
  values (p_batch_label)
  returning id into v_batch_id;

  -- b) promotion -> prospects
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
    s.email, s.phone,

    -- salaires texte -> numeric tolérant
    nullif(replace(regexp_replace(coalesce(s.net_salary,''),'[^0-9,.\-]','','g'),',','.'),'')::numeric,
    case
      when lower(coalesce(s.co_borrower,'')) in ('1','true','t','yes','y','oui','vrai','x') then true
      when lower(coalesce(s.co_borrower,'')) in ('0','false','f','no','n','non') then false
      else null
    end,
    nullif(replace(regexp_replace(coalesce(s.co_net_salary,''),'[^0-9,.\-]','','g'),',','.'),'')::numeric,

    s.comments, s.annexes,
    case
      when lower(coalesce(s.annexes_private,'')) in ('1','true','t','yes','y','oui','vrai','x') then true
      when lower(coalesce(s.annexes_private,'')) in ('0','false','f','no','n','non') then false
      else false
    end,

    -- enums
    case
      when s.employment_status in ('FONCTIONNAIRE','INDEPENDANT','SALA_PRIVE','RETRAITE','CHOMEUR')
        then s.employment_status::public.employment_status_enum
      else null
    end,
    case
      when s.housing_status in ('LOCATAIRE','PROPRIETAIRE','HEBERGE')
        then s.housing_status::public.housing_status_enum
      else null
    end,

    -- GEO : priorité CP ; sinon lookup ville unique ; sinon NULL
    (
      case
        when left(regexp_replace(coalesce(s.postal_code,''),'[^0-9]','','g'),2) in ('75','77','78','91','92','93','94','95')
          then 'IDF'
        when length(left(regexp_replace(coalesce(s.postal_code,''),'[^0-9]','','g'),2)) = 2
          then 'PROVINCE'
        when gl.bucket is not null
          then gl.bucket::text
        else null
      end
    )::public.geo_zone_enum

  from public.staging_raw_prospects s

  -- Choisir UNE seule ligne geo_city_index (qualifier city_norm)
  left join lateral (
    select g.bucket
    from public.geo_city_index g
    where g.city_norm = s.city_norm
      and (s.postal_code is null or g.postal_code = s.postal_code)
    order by (g.postal_code = s.postal_code) desc nulls last
    limit 1
  ) gl on true

  where s.batch_label = p_batch_label;

  GET DIAGNOSTICS v_cnt = ROW_COUNT;

  return query select v_batch_id, v_cnt;
end
$$;

-- 3) droits d'exécution
grant execute on function public.staging_promote_batch(text) to authenticated, service_role;
