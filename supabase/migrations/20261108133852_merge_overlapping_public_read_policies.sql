begin;
drop policy if exists events_owner_read on public.events;
drop policy if exists events_public_read on public.events;
create policy events_select_public_or_owner
on public.events as permissive for select to anon, authenticated
using (
  (status = 'published'::public.event_status and approval_status = 'approved')
  or exists (
    select 1 from public.organisations o
    where o.id = events.organisation_id and o.owner_id = (select auth.uid())
  )
);

drop policy if exists ticket_types_owner_read on public.ticket_types;
drop policy if exists ticket_types_public_read on public.ticket_types;
drop policy if exists ticket_types_verified_owner_manage on public.ticket_types;
create policy ticket_types_select_public_or_owner
on public.ticket_types as permissive for select to anon, authenticated
using (
  exists (
    select 1 from public.events e
    where e.id = ticket_types.event_id
      and e.status = 'published'::public.event_status
      and e.approval_status = 'approved'
  )
  or exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id and o.owner_id = (select auth.uid())
  )
);
create policy ticket_types_verified_owner_insert
on public.ticket_types as permissive for insert to authenticated
with check (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
);
create policy ticket_types_verified_owner_update
on public.ticket_types as permissive for update to authenticated
using (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
)
with check (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
);
create policy ticket_types_verified_owner_delete
on public.ticket_types as permissive for delete to authenticated
using (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
);
commit;
