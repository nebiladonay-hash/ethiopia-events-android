begin;

insert into auth.users(id,email) values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','admin@tiqet.test'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','organizer@tiqet.test');

insert into public.organisations(id,owner_id,name,status) values
 ('20000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Trusted Organizer', 'verified'),
 ('20000000-0000-4000-8000-000000000002','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','New Organizer', 'pending');

insert into public.events(
 id,organisation_id,created_by,title,description,category,starts_at,ends_at,timezone,
 venue_name,address,city,image_url,status,approval_status
) values
 ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'Fight Night','Organizer uploaded fight night poster','Boxing Matches',now()+interval '20 days',now()+interval '20 days 4 hours','Africa/Addis_Ababa',
  'Millennium Hall','Bole Road','Addis Ababa','https://example.test/organizer-owned-banner.jpg','published','approved'),
 ('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'Unapproved Event','Waiting for approval','Music',now()+interval '30 days',null,'Africa/Addis_Ababa',
  'Venue','Road','Addis Ababa',null,'submitted','pending');

insert into public.ticket_types(id,event_id,name,price_etb) values
 ('40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','Ringside',1500),
 ('40000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','General',500);

select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);

select public.set_tiqet_event_spotlight(
 '30000000-0000-4000-8000-000000000001', true, 1, now()+interval '10 days', 'Fight Night Spotlight'
);

do $$ begin
  begin
    perform public.set_tiqet_event_spotlight('30000000-0000-4000-8000-000000000002',true,2,null,'Not approved');
    raise exception 'TEST_ASSERT: unapproved event was featured';
  exception when others then
    if sqlerrm not like '%Only approved and published events can be featured%' then raise; end if;
  end;
end $$;

do $$
declare v jsonb; v_event jsonb; v_ticket_count integer;
begin
  v := public.get_tiqet_spotlight_events(8);
  if jsonb_array_length(v->'events') <> 1 then raise exception 'TEST_ASSERT: incorrect Spotlight event count'; end if;
  v_event := (v->'events')->0;
  if v_event->>'image_url' <> 'https://example.test/organizer-owned-banner.jpg' then
    raise exception 'TEST_ASSERT: organizer artwork was replaced or omitted';
  end if;
  if v_event->>'featured_label' <> 'Fight Night Spotlight' then raise exception 'TEST_ASSERT: spotlight label missing'; end if;
  v_ticket_count := jsonb_array_length(v_event->'ticket_types');
  if v_ticket_count <> 2 then raise exception 'TEST_ASSERT: ticket options were not included'; end if;
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('tiqet-event-banners','tiqet-event-banners',true,8388608,array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
insert into storage.objects(bucket_id,name,owner_id) values(
 'tiqet-event-banners',
 '20000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000001/banner.jpg',
 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
);

select public.set_organiser_event_banner(
 '30000000-0000-4000-8000-000000000001',
 'https://project.supabase.co/storage/v1/object/public/tiqet-event-banners/20000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000001/banner.jpg'
);

do $$ begin
  if (select image_url from public.events where id='30000000-0000-4000-8000-000000000001') not like '%/tiqet-event-banners/%' then
    raise exception 'TEST_ASSERT: organizer banner RPC did not update image_url';
  end if;
end $$;

select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
do $$ begin
  begin
    perform public.set_organiser_event_banner(
      '30000000-0000-4000-8000-000000000001',
      'https://project.supabase.co/storage/v1/object/public/tiqet-event-banners/20000000-0000-4000-8000-000000000002/30000000-0000-4000-8000-000000000001/other.jpg'
    );
    raise exception 'TEST_ASSERT: another organizer changed event banner';
  exception when others then
    if sqlerrm not like '%only update artwork for your own verified organisation events%' then raise; end if;
  end;
end $$;

select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
select public.set_tiqet_event_spotlight('30000000-0000-4000-8000-000000000001',false,1,null,'Tiqet Spotlight');
do $$ begin
  if (select count(*) from public.tiqet_event_spotlight) <> 0 then raise exception 'TEST_ASSERT: unfeature did not remove spotlight'; end if;
  if (select image_url from public.events where id='30000000-0000-4000-8000-000000000001') not like '%/tiqet-event-banners/%' then
    raise exception 'TEST_ASSERT: unfeaturing changed organizer artwork';
  end if;
end $$;

rollback;
