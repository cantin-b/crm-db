set search_path = public;

-- 0) Nettoyage : on droppe les anciennes versions s'il y en a
drop function if exists public.staging_raw_prospects_truncate();
drop function if exists public.staging_raw_prospects_clear_batch(text);

-- 1) TRUNCATE ONLY la table (pas de CASCADE), reset identity
create function public.staging_raw_prospects_truncate()
returns table(truncated boolean, deleted_rows bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cnt bigint;
begin
  select count(*) into v_cnt from public.staging_raw_prospects;
  -- pas de CASCADE : on ne touche à rien d'autre
  execute 'truncate table public.staging_raw_prospects restart identity';
  return query select true, v_cnt;
end
$$;

comment on function public.staging_raw_prospects_truncate()
  is 'Purge TOTALE de staging_raw_prospects (no CASCADE). EXÉCUTION: service_role uniquement.';

-- 2) Suppression d'un lot précis, et reset de la séquence si table vide
create function public.staging_raw_prospects_clear_batch(p_batch_label text)
returns table(deleted_rows bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cnt  bigint;
  v_left bigint;
  v_seq  text;
begin
  delete from public.staging_raw_prospects s
  where s.batch_label = p_batch_label;

  GET DIAGNOSTICS v_cnt = ROW_COUNT;

  select count(*) into v_left from public.staging_raw_prospects;
  if v_left = 0 then
    select pg_get_serial_sequence('public.staging_raw_prospects','id') into v_seq;
    if v_seq is not null then
      perform setval(v_seq, 1, false);
    end if;
  end if;

  return query select v_cnt;
end
$$;

comment on function public.staging_raw_prospects_clear_batch(text)
  is 'Purge PARTIELLE par batch_label dans staging_raw_prospects. EXÉCUTION: service_role uniquement.';

-- 3) Droits : on verrouille. Pas d''exécution publique/clients.
revoke all on function public.staging_raw_prospects_truncate() from public;
revoke all on function public.staging_raw_prospects_clear_batch(text) from public;

grant execute on function public.staging_raw_prospects_truncate() to service_role;
grant execute on function public.staging_raw_prospects_clear_batch(text) to service_role;
