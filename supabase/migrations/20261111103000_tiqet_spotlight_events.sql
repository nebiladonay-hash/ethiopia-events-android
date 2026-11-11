-- Tiqet Spotlight: curated placement for approved events.
-- Event artwork remains organizer-owned in events.image_url. This migration
-- never creates, replaces, or copies organizer artwork.

begin;

create table if not exists public.tiqet_event_spotlight (
  event_id uuid primary key references public.events(id) on delete cascade,
  sort_order integer not null default 100 check (sort_order between 0 and 10000),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  featured_label text not null default 'Tiqet Spotlight'
    check (char_length(featured_label) between 1 and 40),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tiqet_spotlight_valid_window check (ends_at is null or ends_at > starts_at)
);

create index if not exists tiqet_event_spotlight_order_idx
  on public.tiqet_event_spotlight (sort_order asc, starts_at desc);

alter table public.tiqet_event_spotlight enable row level security;
revoke all on public.tiqet_event_spotlight from public, anon, authenticated;
grant select, insert, update, delete on public.tiqet_event_spotlight to service_role;

create or replace function public.get_tiqet_spotlight_events(p_limit integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_events jsonb;
begin
  if p_limit is null or p_limit not between 1 and 20 then
    raise exception 'Limit must be from 1 to 20';
  end if;

  select coalesce(jsonb_agg(x.item order by x.sort_order asc, x.starts_at asc), '[]'::jsonb)
    into v_events
  from (
    select s.sort_order, s.starts_at,
      jsonb_build_object(
        'id', e.id,
        'title', e.title,
        'description', e.description,
        'category', e.category,
        'starts_at', e.starts_at,
        'ends_at', e.ends_at,
        'timezone', e.timezone,
        'venue_name', e.venue_name,
        'address', e.address,
        'city', e.city,
        'image_url', e.image_url,
        'organisation_id', e.organisation_id,
        'organisation_name', o.name,
        'featured_label', s.featured_label
      ) as item
    from public.tiqet_event_spotlight s
    join public.events e on e.id = s.event_id
    join public.organisations o on o.id = e.organisation_id
    where s.starts_at <= now()
      and (s.ends_at is null or s.ends_at > now())
      and e.status = 'published'::public.event_status
      and e.approval_status = 'approved'
      and e.starts_at > now()
    order by s.sort_order asc, s.starts_at asc
    limit p_limit
  ) x;

  return jsonb_build_object('events', v_events);
end;
$$;

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
as $$
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
    if v_event.status <> 'published'::public.event_status or v_event.approval_status <> 'approved' then
      raise exception 'Only approved and published events can be featured';
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
$$;

revoke all on function public.get_tiqet_spotlight_events(integer) from public;
grant execute on function public.get_tiqet_spotlight_events(integer) to anon, authenticated, service_role;
revoke all on function public.set_tiqet_event_spotlight(uuid,boolean,integer,timestamptz,text) from public, anon;
grant execute on function public.set_tiqet_event_spotlight(uuid,boolean,integer,timestamptz,text) to authenticated, service_role;

commit;
