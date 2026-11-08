begin;

-- Trigger-owned and event-trigger functions are not callable through the public Data API.
revoke execute on function public.handle_new_user()
  from public, anon, authenticated;
revoke execute on function public.record_tiqet_revenue_for_paid_order()
  from public, anon, authenticated;
revoke execute on function public.rls_auto_enable()
  from public, anon, authenticated;

-- These RPCs are intentionally exposed to authenticated Tiqet users.
-- Their function bodies enforce auth.uid(), ownership, verified-organisation,
-- inventory and staff checks. Anonymous execution is never permitted.
revoke execute on function public.checkin_ticket(text, uuid, text)
  from public, anon;
revoke execute on function public.claim_free_tickets(uuid, integer)
  from public, anon;
revoke execute on function public.create_event_submission(
  uuid, text, text, text, timestamptz, text, text, text, text, numeric, integer
) from public, anon;
revoke execute on function public.create_order_hold(uuid, integer)
  from public, anon;
revoke execute on function public.submit_event_for_review(uuid)
  from public, anon;

grant execute on function public.checkin_ticket(text, uuid, text) to authenticated;
grant execute on function public.claim_free_tickets(uuid, integer) to authenticated;
grant execute on function public.create_event_submission(
  uuid, text, text, text, timestamptz, text, text, text, text, numeric, integer
) to authenticated;
grant execute on function public.create_order_hold(uuid, integer) to authenticated;
grant execute on function public.submit_event_for_review(uuid) to authenticated;

commit;
