-- Restore backend-only access for Edge Functions that use the service-role client.
-- Client roles keep their existing limited grants and row-level security policies.
grant select, insert, update, delete on table
  public.profiles,
  public.organisations,
  public.events,
  public.ticket_types,
  public.orders,
  public.order_items,
  public.payments,
  public.tickets,
  public.checkins,
  public.event_staff
to service_role;
