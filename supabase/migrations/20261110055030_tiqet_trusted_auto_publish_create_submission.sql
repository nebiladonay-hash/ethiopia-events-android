-- Tiqet: apply trusted auto-publish policy in the actual organizer event-creation RPC.
-- The Android client calls create_event_submission directly; trusted publishing must happen here too.

begin;

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
    venue_name,address,city,status,approval_status
  ) values (
    v_event_id,p_organisation_id,v_user,trim(p_title),coalesce(p_description,''),
    trim(p_category),p_starts_at,trim(p_venue_name),coalesce(trim(p_address),''),
    coalesce(nullif(trim(p_city),''),'Addis Ababa'),v_new_status,v_new_approval
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
    'automatically_published',v_new_status='published'::public.event_status
  );
end;
$$;

revoke all on function public.create_event_submission(uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer) from public,anon;
grant execute on function public.create_event_submission(uuid,text,text,text,timestamptz,text,text,text,text,numeric,integer) to authenticated,service_role;

commit;
