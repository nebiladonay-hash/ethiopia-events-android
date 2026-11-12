-- Tiqet launch mode: instant organiser publishing and simple tiered tickets.
-- Event approval is removed from the create-to-publish path. Ownership, authenticated
-- account access, payout routing, and post-publication takedown remain separate controls.

begin;

-- Public discovery no longer depends on a manual approval flag. Published is the public state.
grant select on public.events, public.ticket_types to anon, authenticated;

drop policy if exists events_public_read_anon on public.events;
create policy events_public_read_anon
on public.events for select to anon
using (status = 'published'::public.event_status);

drop policy if exists events_public_or_owner_authenticated on public.events;
create policy events_public_or_owner_authenticated
on public.events for select to authenticated
using (
  status = 'published'::public.event_status
  or exists (
    select 1 from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
  )
);

drop policy if exists events_verified_org_insert on public.events;
drop policy if exists events_owner_insert on public.events;
create policy events_owner_insert
on public.events for insert to authenticated
with check (
  created_by = (select auth.uid())
  and status in ('draft'::public.event_status, 'published'::public.event_status)
  and exists (
    select 1 from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
  )
);

drop policy if exists events_verified_org_update on public.events;
drop policy if exists events_owner_update on public.events;
create policy events_owner_update
on public.events for update to authenticated
using (
  exists (
    select 1 from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
  )
)
with check (
  created_by = (select auth.uid())
  and status in ('draft'::public.event_status, 'published'::public.event_status)
  and exists (
    select 1 from public.organisations o
    where o.id = events.organisation_id
      and o.owner_id = (select auth.uid())
      and o.status <> 'suspended'::public.organisation_status
  )
);

drop policy if exists ticket_types_public_read_anon on public.ticket_types;
create policy ticket_types_public_read_anon
on public.ticket_types for select to anon
using (
  exists (
    select 1 from public.events e
    where e.id = ticket_types.event_id
      and e.status = 'published'::public.event_status
  )
);

drop policy if exists ticket_types_public_or_owner_authenticated on public.ticket_types;
create policy ticket_types_public_or_owner_authenticated
on public.ticket_types for select to authenticated
using (
  exists (
    select 1 from public.events e
    where e.id = ticket_types.event_id
      and e.status = 'published'::public.event_status
  )
  or exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
  )
);

drop policy if exists ticket_types_verified_owner_insert on public.ticket_types;
create policy ticket_types_owner_insert
on public.ticket_types for insert to authenticated
with check (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and e.status = 'draft'::public.event_status
  )
);

drop policy if exists ticket_types_verified_owner_update on public.ticket_types;
create policy ticket_types_owner_update
on public.ticket_types for update to authenticated
using (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and e.status = 'draft'::public.event_status
  )
)
with check (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and e.status = 'draft'::public.event_status
  )
);

drop policy if exists ticket_types_verified_owner_delete on public.ticket_types;
create policy ticket_types_owner_delete
on public.ticket_types for delete to authenticated
using (
  exists (
    select 1 from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id = ticket_types.event_id
      and o.owner_id = (select auth.uid())
      and e.status = 'draft'::public.event_status
  )
);

-- The authenticated organiser can publish immediately when creating an event.
-- A pending/rejected organisation application does not block free/public listings;
-- paid ticket sales still require an active Chapa settlement destination in the app.
create or replace function public.create_event_with_ticket_options(
  p_organisation_id uuid,
  p_title text,
  p_description text,
  p_category text,
  p_starts_at timestamptz,
  p_venue_name text,
  p_address text,
  p_city text,
  p_ticket_options jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_event_id uuid := gen_random_uuid();
  v_option_count integer;
  v_unique_count integer;
  v_ticket_rows jsonb;
begin
  if v_user is null then raise exception 'Sign in to create an event'; end if;

  if not exists (
    select 1 from public.organisations o
    where o.id = p_organisation_id
      and o.owner_id = v_user
      and o.status <> 'suspended'::public.organisation_status
  ) then
    raise exception 'Your organiser account is unavailable.';
  end if;

  if p_title is null or char_length(btrim(p_title)) not between 3 and 120 then
    raise exception 'Event name must be between 3 and 120 characters';
  end if;
  if p_category is null or char_length(btrim(p_category)) = 0 then
    raise exception 'Choose an event category';
  end if;
  if p_starts_at is null or p_starts_at <= now() then
    raise exception 'Choose a future event date and time';
  end if;
  if p_venue_name is null or char_length(btrim(p_venue_name)) < 2 then
    raise exception 'Enter the event venue';
  end if;
  if p_ticket_options is null or jsonb_typeof(p_ticket_options) is distinct from 'array' then
    raise exception 'Add at least one ticket option (Regular, VIP or VVIP)';
  end if;
  if jsonb_array_length(p_ticket_options) not between 1 and 3 then
    raise exception 'Add between one and three ticket options';
  end if;

  select count(*), count(distinct lower(btrim(x.name)))
    into v_option_count, v_unique_count
  from jsonb_to_recordset(p_ticket_options) as x(name text, price_etb numeric, quantity_total integer);

  if v_option_count not between 1 and 3 or v_unique_count <> v_option_count then
    raise exception 'Ticket options must be unique';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_ticket_options) as x(name text, price_etb numeric, quantity_total integer)
    where x.name is null
       or btrim(x.name) not in ('Regular','VIP','VVIP')
       or x.price_etb is null
       or x.price_etb < 0
       or x.price_etb > 100000000
       or x.quantity_total is null
       or x.quantity_total not between 1 and 100000
  ) then
    raise exception 'Check each ticket price and available quantity';
  end if;

  if not exists (
    select 1 from jsonb_to_recordset(p_ticket_options) as x(name text, price_etb numeric, quantity_total integer)
    where btrim(x.name) = 'Regular'
  ) then
    raise exception 'A Regular ticket option is required';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_ticket_options) as x(name text, price_etb numeric, quantity_total integer)
    where x.price_etb > 0
  ) and not exists (
    select 1 from public.organisations o
    where o.id = p_organisation_id
      and o.owner_id = v_user
      and nullif(btrim(o.payout_account_last4), '') is not null
  ) then
    raise exception 'Connect a settlement account before offering paid tickets';
  end if;

  insert into public.events(
    id, organisation_id, created_by, title, description, category, starts_at,
    venue_name, address, city, status, approval_status
  ) values (
    v_event_id, p_organisation_id, v_user, btrim(p_title),
    coalesce(p_description,''), btrim(p_category), p_starts_at,
    btrim(p_venue_name), coalesce(btrim(p_address), ''),
    coalesce(nullif(btrim(p_city),''), 'Addis Ababa'),
    'published'::public.event_status, 'approved'
  );

  insert into public.ticket_types(
    id, event_id, name, price_etb, quantity_total, per_order_limit
  )
  select
    gen_random_uuid(), v_event_id, btrim(x.name), round(x.price_etb,2),
    x.quantity_total, least(x.quantity_total,10)
  from jsonb_to_recordset(p_ticket_options) as x(name text, price_etb numeric, quantity_total integer)
  order by case btrim(x.name) when 'Regular' then 1 when 'VIP' then 2 else 3 end;

  select jsonb_agg(
    jsonb_build_object('id', t.id, 'name', t.name, 'price_etb', t.price_etb, 'quantity_total', t.quantity_total)
    order by case t.name when 'Regular' then 1 when 'VIP' then 2 else 3 end
  ) into v_ticket_rows
  from public.ticket_types t where t.event_id = v_event_id;

  return jsonb_build_object(
    'event_id', v_event_id,
    'status', 'published',
    'approval_status', 'approved',
    'published_immediately', true,
    'ticket_types', coalesce(v_ticket_rows, '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.create_event_with_ticket_options(uuid,text,text,text,timestamptz,text,text,text,jsonb) from public, anon;
grant execute on function public.create_event_with_ticket_options(uuid,text,text,text,timestamptz,text,text,text,jsonb) to authenticated, service_role;

-- Preserve the older mobile client RPC name, but make it an instant-publish wrapper.
create or replace function public.create_event_submission(
  p_organisation_id uuid,
  p_title text,
  p_description text,
  p_category text,
  p_starts_at timestamptz,
  p_venue_name text,
  p_address text,
  p_city text,
  p_ticket_name text,
  p_price_etb numeric,
  p_quantity integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  return public.create_event_with_ticket_options(
    p_organisation_id,p_title,p_description,p_category,p_starts_at,p_venue_name,
    p_address,p_city,
    jsonb_build_array(jsonb_build_object(
      'name',coalesce(nullif(btrim(p_ticket_name),''),'Regular'),
      'price_etb',p_price_etb,
      'quantity_total',p_quantity
    ))
  );
end;
$function$;

revoke all on function public.create_event_submission(uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer) from public, anon;
grant execute on function public.create_event_submission(uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer) to authenticated, service_role;

-- Legacy draft submissions are also published directly when the organiser presses publish.
create or replace function public.submit_event_for_review(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_event public.events%rowtype;
begin
  if v_user is null then raise exception 'Sign in to publish this event'; end if;

  select e.* into v_event
  from public.events e
  join public.organisations o on o.id = e.organisation_id
  where e.id = p_event_id
    and e.created_by = v_user
    and o.owner_id = v_user
    and o.status <> 'suspended'::public.organisation_status
  for update of e;

  if not found then raise exception 'Your event could not be found'; end if;
  if v_event.status not in ('draft'::public.event_status, 'submitted'::public.event_status) then
    raise exception 'This event is already published or cannot be published';
  end if;
  if not exists (select 1 from public.ticket_types t where t.event_id = p_event_id) then
    raise exception 'Add at least one ticket option before publishing';
  end if;

  update public.events
  set status = 'published'::public.event_status,
      approval_status = 'approved',
      reviewed_by = null,
      reviewed_at = null,
      review_notes = '',
      updated_at = now()
  where id = p_event_id;

  return jsonb_build_object('event_id',p_event_id,'status','published','approval_status','approved','published_immediately',true);
end;
$function$;

revoke all on function public.submit_event_for_review(uuid) from public, anon;
grant execute on function public.submit_event_for_review(uuid) to authenticated, service_role;

-- Spotlight is now simply an admin-curated collection of public events.
create or replace function public.get_tiqet_spotlight_events(p_limit integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare v_events jsonb;
begin
  if p_limit is null or p_limit not between 1 and 20 then
    raise exception 'Limit must be from 1 to 20';
  end if;

  select coalesce(jsonb_agg(x.item order by x.sort_order asc, x.starts_at asc), '[]'::jsonb)
    into v_events
  from (
    select s.sort_order, e.starts_at,
      jsonb_build_object(
        'id', e.id, 'title', e.title, 'description', e.description, 'category', e.category,
        'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone,
        'venue_name', e.venue_name, 'address', e.address, 'city', e.city,
        'image_url', e.image_url, 'organisation_id', e.organisation_id,
        'organisation_name', o.name, 'minimum_price_etb', cheapest.price_etb,
        'ticket_type_id', cheapest.id, 'ticket_type_name', cheapest.name,
        'featured_label', s.featured_label,
        'spotlight_sort_order', s.sort_order, 'spotlight_ends_at', s.ends_at,
        'ticket_types', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', tt.id, 'name', tt.name, 'price_etb', tt.price_etb,
            'quantity_total', tt.quantity_total
          ) order by tt.price_etb asc)
          from public.ticket_types tt
          where tt.event_id = e.id
            and (tt.sales_start is null or tt.sales_start <= now())
            and (tt.sales_end is null or tt.sales_end > now())
        ), '[]'::jsonb)
      ) as item
    from public.tiqet_event_spotlight s
    join public.events e on e.id = s.event_id
    join public.organisations o on o.id = e.organisation_id
    left join lateral (
      select tt.id, tt.name, tt.price_etb
      from public.ticket_types tt
      where tt.event_id = e.id
      order by tt.price_etb asc limit 1
    ) cheapest on true
    where e.image_url is not null
      and btrim(e.image_url) <> ''
      and s.starts_at <= now()
      and (s.ends_at is null or s.ends_at > now())
      and e.status = 'published'::public.event_status
      and e.starts_at > now()
    order by s.sort_order asc, e.starts_at asc
    limit p_limit
  ) x;

  return jsonb_build_object('events', v_events);
end;
$function$;

create or replace function public.set_tiqet_event_spotlight(
  p_event_id uuid,
  p_featured boolean,
  p_sort_order integer default 100,
  p_ends_at timestamptz default null,
  p_featured_label text default 'Tiqet Spotlight'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare v_event public.events%rowtype;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_event_id is null then raise exception 'Event ID is required'; end if;
  if p_featured is null then raise exception 'Featured setting is required'; end if;
  if p_sort_order is null or p_sort_order not between 0 and 10000 then
    raise exception 'Sort order must be from 0 to 10000';
  end if;
  if p_featured_label is null or char_length(btrim(p_featured_label)) not between 1 and 40 then
    raise exception 'Featured label must contain 1 to 40 characters';
  end if;
  if p_ends_at is not null and p_ends_at <= now() then
    raise exception 'Spotlight end time must be in the future';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found'; end if;

  if p_featured then
    if v_event.status <> 'published'::public.event_status then
      raise exception 'Only published events can be featured';
    end if;
    if v_event.image_url is null or btrim(v_event.image_url) = '' then
      raise exception 'The organiser must upload an event banner before featuring';
    end if;
    if v_event.starts_at <= now() then
      raise exception 'Past or currently running events cannot be featured';
    end if;

    insert into public.tiqet_event_spotlight(event_id, sort_order, ends_at, featured_label, created_by, updated_at)
    values (p_event_id, p_sort_order, p_ends_at, btrim(p_featured_label), auth.uid(), now())
    on conflict (event_id) do update set
      sort_order = excluded.sort_order,
      ends_at = excluded.ends_at,
      featured_label = excluded.featured_label,
      updated_at = now();
  else
    delete from public.tiqet_event_spotlight where event_id = p_event_id;
  end if;

  return jsonb_build_object('event_id', p_event_id, 'featured', p_featured);
end;
$function$;

-- Keep the admin's post-publication event catalogue from depending on legacy review flags.
create or replace function public.get_tiqet_published_events_for_review(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_moderator() then
    raise exception 'Tiqet moderator permission required';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Limit must be from 1 to 100';
  end if;

  select coalesce(jsonb_agg(x.item order by x.starts_at asc),'[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id',e.id,'title',e.title,'description',e.description,'category',e.category,
      'starts_at',e.starts_at,'venue_name',e.venue_name,'city',e.city,
      'image_url',e.image_url,'organisation_id',e.organisation_id,
      'organisation_name',o.name,'created_at',e.created_at
    ) item,e.starts_at
    from public.events e
    join public.organisations o on o.id=e.organisation_id
    where e.status='published'::public.event_status
    order by e.starts_at asc
    limit p_limit
  ) x;

  return jsonb_build_object('events',v_rows);
end;
$function$;

revoke all on function public.get_tiqet_spotlight_events(integer) from public;
grant execute on function public.get_tiqet_spotlight_events(integer) to anon, authenticated, service_role;
revoke all on function public.set_tiqet_event_spotlight(uuid,boolean,integer,timestamptz,text) from public, anon;
grant execute on function public.set_tiqet_event_spotlight(uuid,boolean,integer,timestamptz,text) to authenticated, service_role;
revoke all on function public.get_tiqet_published_events_for_review(integer) from public, anon;
grant execute on function public.get_tiqet_published_events_for_review(integer) to authenticated, service_role;

-- Banner upload still requires ownership and an event-specific storage path; it no longer
-- waits for a separate organisation-verification step.
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
  if auth.uid() is null then raise exception 'Sign in to update event artwork'; end if;
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
    and o.id::text = split_part(v_path, '/', 1)
    and e.id::text = split_part(v_path, '/', 2)
  for update of e;
  if not found then raise exception 'You can only update artwork for your own organiser events'; end if;

  if not exists (
    select 1 from storage.objects
    where bucket_id = 'tiqet-event-banners' and name = v_path
  ) then
    raise exception 'Uploaded banner object was not found';
  end if;

  update public.events set image_url = p_image_url, updated_at = now()
  where id = p_event_id;

  return jsonb_build_object('event_id', p_event_id, 'image_url', p_image_url, 'organizer_owned', true);
end;
$function$;

revoke all on function public.set_organiser_event_banner(uuid,text) from public, anon;
grant execute on function public.set_organiser_event_banner(uuid,text) to authenticated;

-- Remove the old admin RPC that required approve/reject/request-changes decisions.
drop function if exists public.review_event_submission(uuid,text,text);
-- Remove the now-obsolete trusted-organiser auto-publish controls. Every non-suspended
-- organiser publishes immediately, so this trust toggle no longer changes event visibility.
drop function if exists public.set_organiser_auto_publish(uuid,boolean,text);
drop function if exists public.get_tiqet_verified_organisers();

commit;
