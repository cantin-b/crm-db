-- 2025-10-20_campaigns-hardening-and-exclude-owned.sql
-- Objectif global :
--  - Fiabiliser l’appartenance aux campagnes et la visibilité opérateur
--  - Exclure, à la création d’une campagne, les prospects déjà assignés (owner_id IS NOT NULL)
--  - Rester rétro-compatible (pas de changement de schéma majeur)

BEGIN;

--------------------------------------------------------------------------------
-- (1) BACKFILL : assurer l’appartenance à partir des assignations existantes
--------------------------------------------------------------------------------
INSERT INTO public.campaign_members (campaign_id, user_id)
SELECT DISTINCT ct.campaign_id, ct.assigned_to
FROM public.campaign_targets ct
WHERE ct.assigned_to IS NOT NULL
ON CONFLICT DO NOTHING;

--------------------------------------------------------------------------------
-- (2) HELPER: peupler tous les opérateurs comme membres d’une campagne (optionnel)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.campaign_members_ensure_all_operators(p_campaign_id bigint)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH ins AS (
    INSERT INTO public.campaign_members(campaign_id, user_id)
    SELECT p_campaign_id, p.id
    FROM public.profiles p
    WHERE p.role = 'operator'
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*) FROM ins;
$$;

--------------------------------------------------------------------------------
-- (3) campaign_create_from_filters :
--     - version durcie + EXCLUSION des prospects déjà assignés (owner_id IS NULL)
--     - membership auto des owners impliqués
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.campaign_create_from_filters(
  p_name text,
  p_batch_ids bigint[],
  p_geo text,
  p_min_salary numeric,
  p_max_salary numeric,
  p_require_email boolean,
  p_require_coborrower boolean,
  p_phoning_status text[],
  p_employment public.employment_status_enum[],
  p_housing public.housing_status_enum[],
  p_member_ids uuid[],
  p_include_employment_null boolean DEFAULT false,
  p_include_housing_null boolean DEFAULT false
)
RETURNS TABLE(campaign_id bigint, created_targets integer, created_members integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_campaign_id bigint;
  v_created_targets int := 0;
  v_created_members int := 0;
  v_uid uuid := auth.uid();

  v_member_ids uuid[] := '{}';
  v_member_count int := 0;

  v_phone_text text[] := '{}';
  v_want_phone_null boolean := false;
begin
  -- garde
  if not (public._is_admin_or_service() or public.is_manager_or_admin()) then
    raise exception 'not allowed';
  end if;

  -- phoning preprocess (comparaison en text)
  if p_phoning_status is not null then
    v_want_phone_null := array_position(p_phoning_status, '__NULL__') is not null;
    v_phone_text := array_remove(p_phoning_status, '__NULL__');
  end if;

  -- 1) campagne
  insert into public.campaigns(name, status, created_by)
  values (p_name, 'INACTIVE', v_uid)
  returning id into v_campaign_id;

  -- 2) membres (ceux fournis)
  if p_member_ids is not null and array_length(p_member_ids,1) is not null then
    insert into public.campaign_members(campaign_id, user_id)
    select distinct v_campaign_id, u from unnest(p_member_ids) u
    on conflict do nothing;
    get diagnostics v_created_members = row_count;

    select array_agg(distinct u order by u) into v_member_ids
    from unnest(p_member_ids) u;
  end if;
  v_member_count := coalesce(array_length(v_member_ids,1),0);

  -- 3) base éligible : mêmes filtres + EXCLURE prospects déjà assignés à un opérateur
  with base as (
    select p.id as prospect_id, p.owner_id
    from public.prospects p
    where
      (p_batch_ids is null or array_length(p_batch_ids,1) is null or p.list_batch_id = any(p_batch_ids))
      and (
        p_geo is null
        or (p_geo = 'FR_METRO' and p.geo_zone in ('IDF','PROVINCE'))
        or (p_geo = 'IDF'      and p.geo_zone = 'IDF')
        or (p_geo = 'PROVINCE' and p.geo_zone = 'PROVINCE')
      )
      and (p_min_salary is null or p.net_salary >= p_min_salary)
      and (p_max_salary is null or p.net_salary <= p_max_salary)
      and (
        coalesce(p_require_email,false) = false
        or (p.email is not null and length(trim(p.email)) > 0)
      )
      and (
        p_require_coborrower is null
        or (p_require_coborrower = true  and coalesce(p.co_borrower,false) = true)
        or (p_require_coborrower = false and coalesce(p.co_borrower,false) = false)
      )
      and (
        p_phoning_status is null
        or (v_want_phone_null and p.phoning_disposition is null)
        or (array_length(v_phone_text,1) is not null and p.phoning_disposition::text = any(v_phone_text))
      )
      and (
        p_employment is null
        or p.employment_status = any(p_employment)
        or (p_include_employment_null and p.employment_status is null)
      )
      and (
        p_housing is null
        or p.housing_status = any(p_housing)
        or (p_include_housing_null and p.housing_status is null)
      )
      and p.owner_id is null
      -- (Option facultative pour exclure aussi tout prospect déjà présent dans n'importe quelle campagne)
      -- and not exists (select 1 from public.campaign_targets t where t.prospect_id = p.id)
  ),
  -- numérotation pour round-robin sur ceux SANS owner
  numbered as (
    select prospect_id, row_number() over (order by prospect_id) as rn
    from base
    where owner_id is null
  ),
  members as (
    select m_id, ord::int
    from unnest(v_member_ids) with ordinality as t(m_id, ord)
  ),
  dispatch as (
    -- a) sécurité (devrait être vide car owner_id is null dans base)
    select b.prospect_id, b.owner_id as chosen
    from base b
    where b.owner_id is not null

    union all

    -- b) attribuer un owner si possible (RR sur la liste fournie)
    select n.prospect_id,
           case when v_member_count > 0
                then (select m.m_id from members m
                      where m.ord = ((n.rn - 1) % v_member_count) + 1)
                else null::uuid
           end as chosen
    from numbered n
  )
  -- 4) poser l’owner (sans écraser)
  , up_owner as (
    update public.prospects p
       set owner_id = d.chosen
    from dispatch d
    where p.id = d.prospect_id
      and p.owner_id is null
      and d.chosen is not null
    returning p.id
  )
  -- 5) insérer les targets
  , ins_targets as (
    insert into public.campaign_targets(campaign_id, prospect_id, assigned_to)
    select v_campaign_id, d.prospect_id, d.chosen
    from dispatch d
    left join public.campaign_targets ct
      on ct.campaign_id = v_campaign_id
     and ct.prospect_id = d.prospect_id
    where ct.prospect_id is null
    returning 1
  )
  -- 6) garantir l’appartenance des owners impactés
  insert into public.campaign_members(campaign_id, user_id)
  select distinct v_campaign_id, p.owner_id
  from public.prospects p
  join public.campaign_targets ct on ct.prospect_id = p.id
  where ct.campaign_id = v_campaign_id
    and p.owner_id is not null
  on conflict do nothing;

  -- 7) miroir final: assigned_to = owner_id
  update public.campaign_targets ct
     set assigned_to = p.owner_id
  from public.prospects p
  where ct.campaign_id = v_campaign_id
    and ct.prospect_id = p.id
    and (ct.assigned_to is distinct from p.owner_id);

  get diagnostics v_created_targets = row_count;

  return query select v_campaign_id, v_created_targets, v_created_members;
end
$function$;

--------------------------------------------------------------------------------
-- (4) Sécuriser campaign_takeover : membership auto du nouveau owner
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.campaign_takeover(
  p_campaign_id bigint,
  p_new_owner uuid,
  p_cancel_future_appts boolean DEFAULT true
)
RETURNS TABLE(transferred integer, appts_canceled integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_transferred int := 0;
  v_canceled    int := 0;
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;

  -- garantir appartenance
  insert into public.campaign_members(campaign_id, user_id)
  values (p_campaign_id, p_new_owner)
  on conflict do nothing;

  update public.campaign_targets
     set assigned_to = p_new_owner
   where campaign_id = p_campaign_id;
  get diagnostics v_transferred = row_count;

  if p_cancel_future_appts then
    update public.appointments a
       set status = 'CANCELED'
     where a.status = 'PLANNED'
       and a.prospect_id in (
         select prospect_id
           from public.campaign_targets
          where campaign_id = p_campaign_id
       );
    get diagnostics v_canceled = row_count;
  end if;

  return query select v_transferred, v_canceled;
end
$function$;

--------------------------------------------------------------------------------
-- (5) Sécuriser campaign_transfer_targets : membership auto du destinataire
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.campaign_transfer_targets(
  p_campaign_id bigint,
  p_from uuid,
  p_to uuid,
  p_cancel_future_appts boolean DEFAULT true
)
RETURNS TABLE(transferred integer, appts_canceled integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_transferred int := 0;
  v_canceled    int := 0;
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;

  -- garantir appartenance du destinataire
  insert into public.campaign_members(campaign_id, user_id)
  values (p_campaign_id, p_to)
  on conflict do nothing;

  -- 1) Transfert global d’ownership (prospects.owner_id)
  update public.prospects p
     set owner_id = p_to
   where p.owner_id = p_from
     and exists (
       select 1
         from public.campaign_targets ct
        where ct.campaign_id = p_campaign_id
          and ct.prospect_id = p.id
     );

  -- 2) Miroir sur campaign_targets
  update public.campaign_targets t
     set assigned_to = p_to
   where t.campaign_id = p_campaign_id
     and t.assigned_to = p_from;
  get diagnostics v_transferred = row_count;

  -- 3) Annule les RDV futurs de l’opérateur remplacé si demandé
  if p_cancel_future_appts then
    update public.appointments a
       set status = 'CANCELED'
     where a.status = 'PLANNED'
       and a.user_id = p_from
       and a.prospect_id in (
         select prospect_id
           from public.campaign_targets
          where campaign_id = p_campaign_id
       );
    get diagnostics v_canceled = row_count;
  end if;

  return query select v_transferred, v_canceled;
end
$function$;

--------------------------------------------------------------------------------
-- (6) CONTRAINTE d’intégrité : assigned_to ∈ members (déférable)
--------------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_constraint c
    JOIN   pg_namespace n ON n.oid = c.connamespace
    WHERE  c.conname = 'fk_target_assignee_is_member'
       AND n.nspname = 'public'
  ) THEN
    ALTER TABLE public.campaign_targets
      ADD CONSTRAINT fk_target_assignee_is_member
      FOREIGN KEY (campaign_id, assigned_to)
      REFERENCES public.campaign_members(campaign_id, user_id)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END$$;

COMMIT;
