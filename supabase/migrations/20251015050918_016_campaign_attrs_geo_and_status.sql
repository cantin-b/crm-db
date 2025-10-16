set search_path = public;

-- ====== Enums nécessaires ======
do $$ begin
  create type employment_status_enum as enum ('FONCTIONNAIRE','INDEPENDANT','SALA_PRIVE','RETRAITE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type housing_status_enum as enum ('LOCATAIRE','PROPRIETAIRE','HEBERGE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type geo_zone_enum as enum ('IDF','PROVINCE','DROMCOM','UNKNOWN');
exception when duplicate_object then null; end $$;

do $$ begin
  create type campaign_status_enum as enum ('INACTIVE','ACTIVE','ARCHIVED');
exception when duplicate_object then null; end $$;

-- ====== Colonnes sur prospects ======
alter table public.prospects
  add column if not exists employment_status employment_status_enum,
  add column if not exists housing_status    housing_status_enum,
  add column if not exists geo_zone          geo_zone_enum;

-- ====== Détermination de la zone géo (priorité au CP) ======
create or replace function public.classify_geo_zone(p_cp text)
returns geo_zone_enum
language plpgsql immutable as $$
declare dept text;
begin
  if p_cp is null or p_cp !~ '^\d{5}$' then
    return 'UNKNOWN';
  end if;

  if left(p_cp,2) = '97' then
    return 'DROMCOM';
  end if;

  dept := left(p_cp,2);
  if dept in ('75','77','78','91','92','93','94','95') then
    return 'IDF';
  end if;

  return 'PROVINCE';
end $$;

create or replace function public.trg_prospect_geo_zone()
returns trigger
language plpgsql as $$
begin
  if new.postal_code is distinct from coalesce(old.postal_code,'__NULL__') then
    new.geo_zone := public.classify_geo_zone(new.postal_code);
  elsif new.geo_zone is null then
    new.geo_zone := public.classify_geo_zone(new.postal_code);
  end if;
  return new;
end $$;

drop trigger if exists trg_prospect_geo_zone on public.prospects;
create trigger trg_prospect_geo_zone
before insert or update on public.prospects
for each row execute function public.trg_prospect_geo_zone();

-- Backfill initial
update public.prospects
   set geo_zone = public.classify_geo_zone(postal_code)
 where geo_zone is null;

-- ====== Statut sur campaigns ======
alter table public.campaigns
  add column if not exists status campaign_status_enum not null default 'INACTIVE';

create index if not exists idx_campaigns_status on public.campaigns(status);

-- ====== Index prospects pour les filtres ======
create index if not exists idx_prospects_geo        on public.prospects (geo_zone);
create index if not exists idx_prospects_salary     on public.prospects (net_salary);
create index if not exists idx_prospects_phoning    on public.prospects (phoning_disposition);
create index if not exists idx_prospects_employment on public.prospects (employment_status);
create index if not exists idx_prospects_housing    on public.prospects (housing_status);

-- Unicité d'une cible par campagne
do $$
begin
  if not exists (
    select 1 from pg_indexes
     where schemaname='public' and indexname='uniq_campaign_target'
  ) then
    execute 'create unique index uniq_campaign_target on public.campaign_targets (campaign_id, prospect_id)';
  end if;
end $$;

-- ====== RLS: masquer les cibles des campagnes non actives aux opérateurs ======
-- On remplace la policy de select sur campaign_targets si elle existe déjà
drop policy if exists sel_targets on public.campaign_targets;
create policy sel_targets on public.campaign_targets
  for select using (
    public.is_manager_or_admin()
    or (
      assigned_to = auth.uid()
      and exists (
        select 1 from public.campaigns c
        where c.id = campaign_targets.campaign_id
          and c.status = 'ACTIVE'
      )
    )
  );

-- RPC utilitaire: changer le statut (admin/manager uniquement)
create or replace function public.campaign_set_status(
  p_campaign_id bigint,
  p_status campaign_status_enum
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_manager_or_admin() then
    raise exception 'Accès refusé (admin/manager requis)';
  end if;
  update public.campaigns
     set status = p_status
   where id = p_campaign_id;
end $$;
