-- Migration 046: Apply campaign status/start/end from filter_json.meta at creation time
-- Safe & backwards-compatible: does not modify existing RPCs or triggers.

-- 1) Function: reads NEW.filter_json->'meta' and applies fields if present/valid.
create or replace function public.trg_campaigns_apply_meta_from_filter_json()
returns trigger
language plpgsql
as $$
declare
  v_meta   jsonb;
  v_status public.campaign_status_enum;
  v_start  date;
  v_end    date;
begin
  if NEW.filter_json is null then
    return NEW;
  end if;

  v_meta := NEW.filter_json->'meta';
  if v_meta is null then
    return NEW;
  end if;

  -- Status: only allow INACTIVE / ACTIVE at creation time.
  if (v_meta ? 'status') then
    begin
      v_status := (v_meta->>'status')::public.campaign_status_enum;
      if v_status in ('INACTIVE','ACTIVE') then
        NEW.status := v_status;
      end if;
    exception when others then
      -- ignore invalid value
      null;
    end;
  end if;

  -- start_at (optional)
  if (v_meta ? 'start_at') then
    begin
      v_start := (v_meta->>'start_at')::date;
      NEW.start_at := v_start;
    exception when others then
      -- ignore parse error
      null;
    end;
  end if;

  -- end_at (optional)
  if (v_meta ? 'end_at') then
    begin
      v_end := (v_meta->>'end_at')::date;
      NEW.end_at := v_end;
    exception when others then
      -- ignore parse error
      null;
    end;
  end if;

  return NEW;
end
$$;

-- 2) Trigger BEFORE INSERT on campaigns.
-- Name prefixed with 00_ so it runs before trg_campaigns_status_audit,
-- ensuring activated_at is set when status=ACTIVE.
drop trigger if exists trg_campaigns_00_apply_meta_from_filter_json on public.campaigns;
create trigger trg_campaigns_00_apply_meta_from_filter_json
before insert on public.campaigns
for each row
execute function public.trg_campaigns_apply_meta_from_filter_json();

-- (Optional) Comment to document expected JSON shape.
comment on function public.trg_campaigns_apply_meta_from_filter_json() is
  'On INSERT, if filter_json.meta is present, applies {status, start_at, end_at} to columns. Status limited to INACTIVE/ACTIVE.';
