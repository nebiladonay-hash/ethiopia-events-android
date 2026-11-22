-- Ensure the public RPC catalogue is refreshed after TIQET functions are introduced.
-- This fixes stale PostgREST schema caches that otherwise return PGRST202 for valid RPCs.

do $$
begin
  if to_regprocedure('public.get_tiqet_spotlight_events(integer)') is null then
    raise exception 'TIQET Spotlight RPC is missing; apply the Spotlight migration first.';
  end if;
end;
$$;

grant execute on function public.get_tiqet_spotlight_events(integer)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
