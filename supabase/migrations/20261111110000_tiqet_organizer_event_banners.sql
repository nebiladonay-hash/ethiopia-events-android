-- Organizer-owned event banners. Public event artwork remains controlled by
-- each verified organizer; Spotlight metadata never writes image_url.

begin;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'tiqet-event-banners',
  'tiqet-event-banners',
  true,
  8388608,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = true,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists tiqet_event_banners_owner_insert on storage.objects;
create policy tiqet_event_banners_owner_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'tiqet-event-banners'
  and coalesce(array_length(storage.foldername(name), 1), 0) >= 2
  and exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id::text = (storage.foldername(name))[2]
      and o.id::text = (storage.foldername(name))[1]
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
  )
);

drop policy if exists tiqet_event_banners_owner_update on storage.objects;
create policy tiqet_event_banners_owner_update
on storage.objects for update to authenticated
using (
  bucket_id = 'tiqet-event-banners'
  and coalesce(array_length(storage.foldername(name), 1), 0) >= 2
  and exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id::text = (storage.foldername(name))[2]
      and o.id::text = (storage.foldername(name))[1]
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
  )
)
with check (
  bucket_id = 'tiqet-event-banners'
  and coalesce(array_length(storage.foldername(name), 1), 0) >= 2
  and exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id::text = (storage.foldername(name))[2]
      and o.id::text = (storage.foldername(name))[1]
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
  )
);

drop policy if exists tiqet_event_banners_owner_delete on storage.objects;
create policy tiqet_event_banners_owner_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'tiqet-event-banners'
  and coalesce(array_length(storage.foldername(name), 1), 0) >= 2
  and exists (
    select 1
    from public.events e
    join public.organisations o on o.id = e.organisation_id
    where e.id::text = (storage.foldername(name))[2]
      and o.id::text = (storage.foldername(name))[1]
      and o.owner_id = (select auth.uid())
      and o.status = 'verified'::public.organisation_status
  )
);

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
    and o.owner_id = auth.uid()
    and o.status = 'verified'::public.organisation_status
    and o.id::text = split_part(v_path, '/', 1)
    and e.id::text = split_part(v_path, '/', 2)
  for update of e;
  if not found then raise exception 'You can only update artwork for your own verified organisation events'; end if;

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

commit;
