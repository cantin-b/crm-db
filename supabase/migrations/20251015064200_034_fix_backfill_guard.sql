set search_path = public;

-- 1) Recreate the sync function with a migration-safe guard.
drop function if exists public.campaign_targets_sync_from_owner(
  bigint, uuid[], boolean
);

create function public.campaign_targets_sync_from_owner(
  p_campaign_id bigint,
  p_member_ids uuid[] default null,
  p_mirror_only boolean default false
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assigned int := 0;
  v_members uuid[] := coalesce(p_member_ids, '{}');
  v_mcnt int := coalesce(array_length(v_members,1), 0);
begin
  -- ✅ Guard: allow service/admin at runtime, and also allow when auth.uid() is NULL (migrations)
  if not (public._is_admin_or_service() or public.is_manager_or_admin() or auth.uid() is null) then
    raise exception 'not allowed';
  end if;

  -- 1) Mirror owner_id -> campaign_targets.assigned_to (update existants)
  update public.campaign_targets ct
     set assigned_to = p.owner_id
    from public.prospects p
   where ct.campaign_id = p_campaign_id
     and ct.prospect_id = p.id
     and coalesce(ct.assigned_to,'00000000-0000-0000-0000-000000000000'::uuid) is distinct from p.owner_id;

  -- 2) Si on ne veut QUE mirrorer, on s'arrête ici
  if p_mirror_only then
    get diagnostics v_assigned = row_count;
    return v_assigned;
  end if;

  -- 3) Pour les cibles de la campagne qui n'ont PAS d'owner_id,
  --    si on a des membres, on fait un round-robin et on pousse dans prospects.owner_id
  if v_mcnt > 0 then
    with without_owner as (
      select ct.prospect_id,
             row_number() over (order by ct.id) as rn
        from public.campaign_targets ct
        join public.prospects p on p.id = ct.prospect_id
       where ct.campaign_id = p_campaign_id
         and p.owner_id is null
    ), members as (
      select m_id, ord::int
        from unnest(v_members) with ordinality as t(m_id, ord)
    ), rr as (
      select w.prospect_id,
             (select m.m_id
                from members m
               where m.ord = ((w.rn - 1) % v_mcnt) + 1) as new_owner
        from without_owner w
    )
    update public.prospects p
       set owner_id = rr.new_owner
      from rr
     where p.id = rr.prospect_id
       and p.owner_id is null;

    -- 4) Re-mirror vers campaign_targets.assigned_to (pour ces lignes)
    update public.campaign_targets ct
       set assigned_to = p.owner_id
      from public.prospects p
     where ct.campaign_id = p_campaign_id
       and ct.prospect_id = p.id
       and ct.assigned_to is distinct from p.owner_id;
  end if;

  -- Combien ont une assignation après sync ?
  select count(*)
    into v_assigned
    from public.campaign_targets ct
    where ct.campaign_id = p_campaign_id
      and ct.assigned_to is not null;

  return v_assigned;
end
$$;

revoke all on function public.campaign_targets_sync_from_owner(bigint,uuid[],boolean) from public;
grant execute on function public.campaign_targets_sync_from_owner(bigint,uuid[],boolean) to authenticated, service_role;

-- 2) Backfill: relancer la sync pour toutes les campagnes
do $$
declare
  r record;
  members uuid[];
begin
  for r in select c.id from public.campaigns c order by c.id loop
    select array_agg(cm.user_id order by cm.user_id)
      into members
      from public.campaign_members cm
     where cm.campaign_id = r.id;

    perform public.campaign_targets_sync_from_owner(r.id, members, false);
  end loop;
end$$;
