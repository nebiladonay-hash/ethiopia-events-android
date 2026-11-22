-- Prevent an organiser from undoing a moderation action by directly updating a submitted event.
-- New events still publish immediately. Only the event's existing state controls owner editability.
begin;

drop policy if exists events_owner_update on public.events;

create policy events_owner_update
on public.events
for update
to authenticated
using (
  status = any (array[
    'draft'::public.event_status,
    'published'::public.event_status
  ])
  and exists (
    select 1
    from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
  )
)
with check (
  created_by = (select auth.uid())
  and status = any (array[
    'draft'::public.event_status,
    'published'::public.event_status
  ])
  and exists (
    select 1
    from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
  )
);

commit;
