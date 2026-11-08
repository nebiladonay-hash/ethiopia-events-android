begin;

drop policy if exists events_select_public_or_owner on public.events;
create policy events_public_read_anon
on public.events as permissive for select to anon
using (
  status = 'published'::public.event_status
  and approval_status = 'approved'
);
create policy events_public_or_owner_authenticated
on public.events as permissive for select to authenticated
using (
  (status = 'published'::public.event_status and approval_status = 'approved')
  or exists (
    select 1 from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
  )
);

drop policy if exists ticket_types_select_public_or_owner on public.ticket_types;
create policy ticket_types_public_read_anon
on public.ticket_types as permissive for select to anon
using (
  exists (
    select 1 from public.events e
    where e.id = ticket_types.event_id
      and e.status = 'published'::public.event_status
      and e.approval_status = 'approved'
  )
);
create policy ticket_types_public_or_owner_authenticated
on public.ticket_types as permissive for select to authenticated
using (
  exists (
    select 1 from public.events e
    where e.id = ticket_types.event_id
      and e.status = 'published'::public.event_status
      and e.approval_status = 'approved'
  )
  or exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
  )
);

commit;
