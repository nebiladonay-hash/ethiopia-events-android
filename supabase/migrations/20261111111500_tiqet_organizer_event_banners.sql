-- Organizer-owned event banners stored in a public, constrained image bucket.
-- The event row only accepts a URL belonging to the uploader's own organisation path.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-banners',
  'event-banners',
  true,
  8388608,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = true,
  file_size_limit = 8388608,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

create or replace function public.can_upload_tiqet_event_banner(p_organisation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.organisations o
    where o.id = p_organisation_id
      and o.owner_id = auth.uid()
      and o.status = 'verified'::public.organisation_status
  );
$$;

revoke all on function public.can_upload_tiqet_event_banner(uuid) from public, anon;
grant execute on function public.can_upload_tiqet_event_banner(uuid) to authenticated, service_role;

drop policy if exists "Tiqet verified organisers upload their own event banners" on storage.objects;
create policy "Tiqet verified organisers upload their own event banners"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'event-banners'
  and split_part(name, '/', 1) = 'organisations'
  and split_part(name, '/', 2) ~ '^[0-9a-fA-F-]{36}$'
  and split_part(name, '/', 3) ~ '^banner-[0-9a-fA-F-]{36}\.(jpg|png|webp)$'
  and public.can_upload_tiqet_event_banner(split_part(name, '/', 2)::uuid)
);

drop policy if exists "Tiqet verified organisers delete their own event banners" on storage.objects;
create policy "Tiqet verified organisers delete their own event banners"
on storage.objects for delete to authenticated
using (
  bucket_id = 'event-banners'
  and split_part(name, '/', 1) = 'organisations'
  and split_part(name, '/', 2) ~ '^[0-9a-fA-F-]{36}$'
  and split_part(name, '/', 3) ~ '^banner-[0-9a-fA-F-]{36}\.(jpg|png|webp)$'
  and public.can_upload_tiqet_event_banner(split_part(name, '/', 2)::uuid)
);

drop function if exists public.create_event_submission(
  uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer
);

create function public.create_event_submission(
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
  p_quantity integer,
  p_image_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_event_id uuid := gen_random_uuid();
  v_ticket_type_id uuid := gen_random_uuid();
  v_auto_publish boolean := false;
  v_is_flagged boolean := false;
  v_new_status public.event_status;
  v_new_approval text;
  v_banner_prefix text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.organisations o
    where o.id=p_organisation_id and o.owner_id=v_user
      and o.status='verified'::public.organisation_status
  ) then raise exception 'A verified organisation is required'; end if;
  if p_title is null or char_length(trim(p_title)) not between 3 and 120 then
    raise exception 'Event title must be between 3 and 120 characters';
  end if;
  if p_category is null or char_length(trim(p_category))=0 then raise exception 'Event category is required'; end if;
  if p_starts_at is null or p_starts_at<=now() then raise exception 'Choose a future event date and time'; end if;
  if p_venue_name is null or char_length(trim(p_venue_name))<2 then raise exception 'Venue name is required'; end if;
  if p_ticket_name is null or char_length(trim(p_ticket_name)) not between 2 and 60 then
    raise exception 'Ticket name must be between 2 and 60 characters';
  end if;
  if p_price_etb is null or p_price_etb<0 then raise exception 'Ticket price cannot be negative'; end if;
  if p_quantity is null or p_quantity<1 or p_quantity>100000 then
    raise exception 'Ticket quantity must be between 1 and 100000';
  end if;

  if p_image_url is not null then
    v_banner_prefix := 'https://ebrrdmxyoioefoprtict.supabase.co/storage/v1/object/public/event-banners/organisations/' || p_organisation_id::text || '/banner-';
    if left(p_image_url, length(v_banner_prefix)) <> v_banner_prefix
       or p_image_url !~ '^https://ebrrdmxyoioefoprtict\.supabase\.co/storage/v1/object/public/event-banners/organisations/[0-9a-fA-F-]{36}/banner-[0-9a-fA-F-]{36}\.(jpg|png|webp)$' then
      raise exception 'Event banner must be uploaded by this verified organisation to Tiqet event storage';
    end if;
  end if;

  select coalesce(t.auto_publish_enabled,false) into v_auto_publish
  from public.tiqet_trusted_organisers t where t.organisation_id=p_organisation_id;
  v_auto_publish:=coalesce(v_auto_publish,false);

  select coalesce(f.is_active,false) into v_is_flagged
  from public.tiqet_event_review_flags f where f.event_id=v_event_id;
  v_is_flagged:=coalesce(v_is_flagged,false);

  if v_auto_publish and not v_is_flagged then
    v_new_status:='published'::public.event_status;
    v_new_approval:='approved';
  else
    v_new_status:='submitted'::public.event_status;
    v_new_approval:='pending';
  end if;

  insert into public.events(
    id,organisation_id,created_by,title,description,category,starts_at,
    venue_name,address,city,image_url,status,approval_status
  ) values (
    v_event_id,p_organisation_id,v_user,trim(p_title),coalesce(p_description,''),
    trim(p_category),p_starts_at,trim(p_venue_name),coalesce(trim(p_address),''),
    coalesce(nullif(trim(p_city),''),'Addis Ababa'),p_image_url,v_new_status,v_new_approval
  );

  insert into public.ticket_types(id,event_id,name,price_etb,quantity_total,per_order_limit)
  values(v_ticket_type_id,v_event_id,trim(p_ticket_name),round(p_price_etb,2),p_quantity,least(p_quantity,10));

  if v_new_status='published'::public.event_status then
    insert into public.tiqet_admin_audit_log(actor_user_id,action,target_type,target_id,reason,after_state)
    values(v_user,'trusted_organiser_event_auto_published','event',v_event_id,
      'Trusted organiser auto-publish policy',
      jsonb_build_object('organisation_id',p_organisation_id,'status','published','created_via','create_event_submission'));
  end if;

  return jsonb_build_object(
    'event_id',v_event_id,'ticket_type_id',v_ticket_type_id,
    'status',v_new_status::text,'approval_status',v_new_approval,
    'automatically_published',v_new_status='published'::public.event_status,
    'banner_uploaded',p_image_url is not null
  );
end;
$$;

revoke all on function public.create_event_submission(uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer,text) from public,anon;
grant execute on function public.create_event_submission(uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer,text) to authenticated,service_role;

commit;
