begin;

-- webhook_events is backend-only. Keep RLS enabled with no client policies.
-- Supabase REST upsert uses SELECT + INSERT + UPDATE under service_role.
revoke all privileges on table public.webhook_events
  from anon, authenticated, service_role;
grant select, insert, update on table public.webhook_events to service_role;

commit;
