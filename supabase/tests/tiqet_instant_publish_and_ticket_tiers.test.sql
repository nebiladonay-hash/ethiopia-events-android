begin;

insert into auth.users(id,email) values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','admin@tiqet.test'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','new-organiser@tiqet.test'),
 ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','rejected-organiser@tiqet.test'),
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','suspended-organiser@tiqet.test');

insert into public.organisations(id,owner_id,name,status,payout_account_last4) values
 ('20000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Another Organiser','verified',null),
 ('20000000-0000-4000-8000-000000000002','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','New Organiser','pending',null),
 ('20000000-0000-4000-8000-000000000003','cccccccc-cccc-4ccc-8ccc-cccccccccccc','Rejected Organiser','rejected',null),
 ('20000000-0000-4000-8000-000000000004','dddddddd-dddd-4ddd-8ddd-dddddddddddd','Suspended Organiser','suspended',null);

-- An authenticated organiser must not be able to publish paid tickets before connecting a settlement destination.
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
-- A pending organiser can publish a free event immediately without waiting for approval or a bank account.
create temporary table tiqet_test_free_event(event_id uuid not null);
grant select on tiqet_test_free_event to anon, authenticated;
insert into tiqet_test_free_event(event_id)
select (public.create_event_with_ticket_options(
  '20000000-0000-4000-8000-000000000002',
  'Free Community Meetup',
  '',
  'Culture',
  now()+interval '14 days',
  'Community Hall',
  '',
  'Addis Ababa',
  '[{"name":"Regular","price_etb":0,"quantity_total":120}]'::jsonb
)->>'event_id')::uuid;

do $pending_free_publish_test$ begin
  if not exists (
    select 1 from public.events e
    where e.id=(select event_id from tiqet_test_free_event)
      and e.status='published'::public.event_status
  ) then
    raise exception 'TEST_ASSERT: pending organiser free event did not publish immediately';
  end if;
end $pending_free_publish_test$;

do $paid_gate_test$ begin
  begin
    perform public.create_event_with_ticket_options(
      '20000000-0000-4000-8000-000000000002',
      'Paid Event Before Settlement',
      '',
      'Music',
      now()+interval '21 days',
      'A Venue',
      '',
      'Addis Ababa',
      '[{"name":"Regular","price_etb":250,"quantity_total":100}]'::jsonb
    );
    raise exception 'TEST_ASSERT: paid ticket event bypassed the settlement-account gate';
  exception when others then
    if sqlerrm not like '%Connect a settlement account before offering paid tickets%' then raise; end if;
  end;
end $paid_gate_test$;

-- A rejected-but-not-suspended profile is also allowed to publish a free event immediately.
select set_config('request.jwt.claim.sub','cccccccc-cccc-4ccc-8ccc-cccccccccccc',true);
create temporary table tiqet_test_rejected_event(event_id uuid not null);
grant select on tiqet_test_rejected_event to anon, authenticated;
insert into tiqet_test_rejected_event(event_id)
select (public.create_event_with_ticket_options(
  '20000000-0000-4000-8000-000000000003',
  'Independent Music Gathering',
  '',
  'Music',
  now()+interval '18 days',
  'Open Air Stage',
  '',
  'Addis Ababa',
  '[{"name":"Regular","price_etb":0,"quantity_total":75}]'::jsonb
)->>'event_id')::uuid;
do $rejected_free_publish_test$ begin
  if not exists (
    select 1 from public.events e
    where e.id=(select event_id from tiqet_test_rejected_event)
      and e.status='published'::public.event_status
  ) then
    raise exception 'TEST_ASSERT: rejected organiser profile still blocked instant event publishing';
  end if;
end $rejected_free_publish_test$;

-- A suspended organiser remains blocked as a separate account-level enforcement action.
select set_config('request.jwt.claim.sub','dddddddd-dddd-4ddd-8ddd-dddddddddddd',true);
do $suspended_publish_test$ begin
  begin
    perform public.create_event_with_ticket_options(
      '20000000-0000-4000-8000-000000000004',
      'Suspended Account Event',
      '',
      'Music',
      now()+interval '18 days',
      'Another Venue',
      '',
      'Addis Ababa',
      '[{"name":"Regular","price_etb":0,"quantity_total":75}]'::jsonb
    );
    raise exception 'TEST_ASSERT: suspended organiser published an event';
  exception when others then
    if sqlerrm not like '%organiser account is unavailable%' then raise; end if;
  end;
end $suspended_publish_test$;

-- Continue with the new pending organiser's paid-ticket settlement gate.
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
-- Once the organiser connects a payout destination, all three tier options can be published at once.
update public.organisations
set payout_account_last4='6789'
where id='20000000-0000-4000-8000-000000000002';

create temporary table tiqet_test_created_event(event_id uuid not null);
grant select on tiqet_test_created_event to anon, authenticated;

insert into tiqet_test_created_event(event_id)
select (public.create_event_with_ticket_options(
  '20000000-0000-4000-8000-000000000002',
  'Community Music Night',
  'A locally organised live event',
  'Music',
  now()+interval '21 days',
  'Millennium Hall',
  'Bole Road',
  'Addis Ababa',
  '[
    {"name":"Regular","price_etb":250,"quantity_total":300},
    {"name":"VIP","price_etb":750,"quantity_total":80},
    {"name":"VVIP","price_etb":1500,"quantity_total":20}
  ]'::jsonb
)->>'event_id')::uuid;

do $instant_publish_test$
declare
  v_event_id uuid;
  v_event public.events%rowtype;
  v_ticket_count integer;
  v_names text[];
begin
  select event_id into v_event_id from tiqet_test_created_event;
  select * into v_event from public.events where id=v_event_id;
  if v_event.status <> 'published'::public.event_status then
    raise exception 'TEST_ASSERT: event was not published immediately';
  end if;
  if v_event.approval_status <> 'approved' then
    raise exception 'TEST_ASSERT: event did not get the launch-mode public state';
  end if;
  if v_event.organisation_id <> '20000000-0000-4000-8000-000000000002'::uuid then
    raise exception 'TEST_ASSERT: event was not attached to the organiser-owned profile';
  end if;

  select count(*), array_agg(name order by case name when 'Regular' then 1 when 'VIP' then 2 else 3 end)
  into v_ticket_count,v_names
  from public.ticket_types where event_id=v_event_id;

  if v_ticket_count <> 3 then
    raise exception 'TEST_ASSERT: expected Regular, VIP and VVIP ticket options';
  end if;
  if v_names <> array['Regular','VIP','VVIP'] then
    raise exception 'TEST_ASSERT: ticket tier names/order incorrect: %', v_names;
  end if;
  if (select quantity_total from public.ticket_types where event_id=v_event_id and name='Regular') <> 300 then
    raise exception 'TEST_ASSERT: Regular ticket quantity did not persist';
  end if;
  if (select price_etb from public.ticket_types where event_id=v_event_id and name='VIP') <> 750 then
    raise exception 'TEST_ASSERT: VIP ticket price did not persist';
  end if;
end $instant_publish_test$;

-- The old approval_status flag is no longer a public-discovery gate for a published event.
select set_config('tiqet.test.event_id',(select event_id::text from tiqet_test_created_event),true);
update public.events
set approval_status='pending'
where id=(select event_id from tiqet_test_created_event);

set role anon;
do $public_listing_test$
declare v_event_id uuid := current_setting('tiqet.test.event_id')::uuid;
begin
  if not exists (select 1 from public.events where id=v_event_id and status='published') then
    raise exception 'TEST_ASSERT: public listing still requires manual approval';
  end if;
  if (select count(*) from public.ticket_types where event_id=v_event_id) <> 3 then
    raise exception 'TEST_ASSERT: public ticket options are hidden for a published event';
  end if;
end $public_listing_test$;
reset role;

-- Pending organiser profiles can upload their own banner; the image is normalized on device
-- before it reaches this bucket, while Storage ownership remains enforced by RLS.
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
set role authenticated;
insert into storage.objects(bucket_id,name,owner_id) values(
  'tiqet-event-banners',
  '20000000-0000-4000-8000-000000000002/' ||
    (select event_id::text from tiqet_test_created_event) || '/poster.jpg',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
);

select public.set_organiser_event_banner(
  (select event_id from tiqet_test_created_event),
  'https://project.supabase.co/storage/v1/object/public/tiqet-event-banners/20000000-0000-4000-8000-000000000002/' ||
  (select event_id::text from tiqet_test_created_event) || '/poster.jpg'
);

do $banner_assignment_test$ begin
  if not exists (
    select 1 from public.events
    where id=(select event_id from tiqet_test_created_event)
      and image_url like '%/tiqet-event-banners/%'
  ) then
    raise exception 'TEST_ASSERT: pending organiser could not attach its uploaded artwork';
  end if;
end $banner_assignment_test$;
reset role;

-- A different organiser cannot upload into or assign artwork to this event.
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
set role authenticated;
do $cross_owner_test$ begin
  begin
    insert into storage.objects(bucket_id,name,owner_id) values(
      'tiqet-event-banners',
      '20000000-0000-4000-8000-000000000002/' ||
        (select event_id::text from tiqet_test_created_event) || '/wrong-owner.jpg',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    );
    raise exception 'TEST_ASSERT: different organiser could upload into another organiser event';
  exception when insufficient_privilege then
    null;
  end;
end $cross_owner_test$;

do $cross_assign_test$ begin
  begin
    perform public.set_organiser_event_banner(
      (select event_id from tiqet_test_created_event),
      'https://project.supabase.co/storage/v1/object/public/tiqet-event-banners/20000000-0000-4000-8000-000000000002/' ||
      (select event_id::text from tiqet_test_created_event) || '/poster.jpg'
    );
    raise exception 'TEST_ASSERT: different organiser could assign another organiser banner';
  exception when others then
    if sqlerrm not like '%only update artwork for your own organiser events%' then raise; end if;
  end;
end $cross_assign_test$;
reset role;

-- Spotlight eligibility is now about a live, future event with artwork, not pre-publication approval.
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
select public.set_tiqet_event_spotlight(
  (select event_id from tiqet_test_created_event),
  true,
  4,
  now()+interval '10 days',
  'Community Pick'
);

do $spotlight_no_approval_test$ begin
  if jsonb_array_length(public.get_tiqet_spotlight_events(8)->'events') <> 1 then
    raise exception 'TEST_ASSERT: public Spotlight still requires the approval flag';
  end if;
end $spotlight_no_approval_test$;

rollback;
