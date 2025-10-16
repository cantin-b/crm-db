create index if not exists idx_prospects_email        on public.prospects (email);
create index if not exists idx_prospects_phone        on public.prospects (phone_e164);
create index if not exists idx_prospects_stage        on public.prospects (stage);
create index if not exists idx_prospects_owner        on public.prospects (owner_id);
create index if not exists idx_prospects_listbatch    on public.prospects (list_batch_id);

create index if not exists idx_call_logs_prospect_ts  on public.call_logs (prospect_id, started_at desc);
create index if not exists idx_call_logs_operator_ts  on public.call_logs (operator_id, started_at desc);

create index if not exists idx_targets_assigned       on public.campaign_targets (assigned_to);
create index if not exists idx_targets_campaign       on public.campaign_targets (campaign_id);

create index if not exists idx_valid_steps_prospect   on public.validation_steps (prospect_id, done_at);
