-- Prevent suspended organiser accounts from mutating ticket inventory or uploading artwork.
-- Applied to TIQET-production as migration 20261122142618_tiqet_suspended_organizer_guards_and_fk_indexes.

begin;

drop policy if exists ticket_types_owner_insert on public.ticket_types;
create policy ticket_types_owner_insert
on public.ticket_types
for insert
to authenticated
with check (
  exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
);

drop policy if exists ticket_types_owner_update on public.ticket_types;
create policy ticket_types_owner_update
on public.ticket_types
for update
to authenticated
using (
  exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
)
with check (
  exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
);

drop policy if exists ticket_types_owner_delete on public.ticket_types;
create policy ticket_types_owner_delete
on public.ticket_types
for delete
to authenticated
using (
  exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
      and e.status = 'draft'::public.event_status
  )
);

create or replace function public.can_upload_tiqet_event_banner(
  p_organisation_id uuid,
  p_event_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = p_event_id
      and o.id = p_organisation_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
  );
$function$;

revoke all on function public.can_upload_tiqet_event_banner(uuid,uuid) from public, anon;
grant execute on function public.can_upload_tiqet_event_banner(uuid,uuid) to authenticated, service_role;

create or replace function public.set_organiser_event_banner(
  p_event_id uuid,
  p_image_url text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_event public.events%rowtype;
  v_path text;
begin
  if auth.uid() is null then
    raise exception 'Sign in to update event artwork';
  end if;

  if p_event_id is null or p_image_url is null or char_length(p_image_url) > 1200 then
    raise exception 'Invalid event banner request';
  end if;

  v_path := split_part(p_image_url, '/storage/v1/object/public/tiqet-event-banners/', 2);
  if v_path = '' or v_path = p_image_url or position('..' in v_path) > 0 then
    raise exception 'Banner must be uploaded to the Tiqet event banner bucket';
  end if;

  select e.* into v_event
  from public.events e
  join public.organisations o on o.id = e.organisation_id
  where e.id = p_event_id
    and o.owner_id = (select auth.uid())
    and o.status <> 'suspended'::public.organisation_status
    and o.id::text = split_part(v_path, '/', 1)
    and e.id::text = split_part(v_path, '/', 2)
  for update of e;

  if not found then
    raise exception 'You can only update artwork for your own organiser events';
  end if;

  if not exists (
    select 1 from storage.objects
    where bucket_id = 'tiqet-event-banners'
      and name = v_path
  ) then
    raise exception 'Uploaded banner object was not found';
  end if;

  update public.events
  set image_url = p_image_url, updated_at = now()
  where id = p_event_id;

  return jsonb_build_object(
    'event_id', p_event_id,
    'image_url', p_image_url,
    'organizer_owned', true
  );
end;
$function$;

revoke all on function public.set_organiser_event_banner(uuid,text) from public, anon;
grant execute on function public.set_organiser_event_banner(uuid,text) to authenticated, service_role;

-- These tables are present in production. Conditional DDL lets the focused PostgreSQL
-- regression harness exercise the RLS changes without pretending it contains payment schemas.
do $indexes$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='chapa_refund_operations' and column_name='order_id') then
    execute 'create index if not exists chapa_refund_operations_order_id_idx on public.chapa_refund_operations(order_id)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='events' and column_name='reviewed_by') then
    execute 'create index if not exists events_reviewed_by_idx on public.events(reviewed_by)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='organisations' and column_name='reviewed_by') then
    execute 'create index if not exists organisations_reviewed_by_idx on public.organisations(reviewed_by)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='tiqet_admin_audit_log' and column_name='actor_user_id') then
    execute 'create index if not exists tiqet_admin_audit_log_actor_user_id_idx on public.tiqet_admin_audit_log(actor_user_id)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='tiqet_event_review_flags' and column_name='flagged_by') then
    execute 'create index if not exists tiqet_event_review_flags_flagged_by_idx on public.tiqet_event_review_flags(flagged_by)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='tiqet_event_review_flags' and column_name='resolved_by') then
    execute 'create index if not exists tiqet_event_review_flags_resolved_by_idx on public.tiqet_event_review_flags(resolved_by)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='tiqet_event_spotlight' and column_name='created_by') then
    execute 'create index if not exists tiqet_event_spotlight_created_by_idx on public.tiqet_event_spotlight(created_by)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='tiqet_staff_roles' and column_name='granted_by') then
    execute 'create index if not exists tiqet_staff_roles_granted_by_idx on public.tiqet_staff_roles(granted_by)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='tiqet_trusted_organisers' and column_name='granted_by') then
    execute 'create index if not exists tiqet_trusted_organisers_granted_by_idx on public.tiqet_trusted_organisers(granted_by)';
  end if;
end;
$indexes$;

commit;
