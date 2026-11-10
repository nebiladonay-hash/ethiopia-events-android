-- Tiqet Control: staff roles, organizer verification and event review workflow.
-- Initial production super-admin assignment is performed separately and is not
-- hardcoded here so no founder email or account identifier is published in source.

begin;

create table if not exists public.tiqet_staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('moderator','admin','super_admin')),
  granted_by uuid references auth.users(id) on delete set null,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.tiqet_staff_roles enable row level security;
revoke all on public.tiqet_staff_roles from anon, authenticated;
grant all on public.tiqet_staff_roles to service_role;

create table if not exists public.tiqet_admin_audit_log (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text not null,
  target_id uuid,
  reason text not null default '',
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz not null default now()
);
create index if not exists tiqet_admin_audit_log_created_idx
  on public.tiqet_admin_audit_log(created_at desc);
create index if not exists tiqet_admin_audit_log_target_idx
  on public.tiqet_admin_audit_log(target_type,target_id,created_at desc);
alter table public.tiqet_admin_audit_log enable row level security;
revoke all on public.tiqet_admin_audit_log from anon, authenticated;
grant all on public.tiqet_admin_audit_log to service_role;

alter table public.organisations
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists reviewed_at timestamptz;
alter table public.events
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_notes text not null default '';

create index if not exists organisations_review_queue_idx
  on public.organisations(status,created_at desc);
create index if not exists events_review_queue_idx
  on public.events(approval_status,status,created_at desc);

create or replace function public.is_tiqet_moderator()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tiqet_staff_roles r
    where r.user_id = (select auth.uid())
      and r.role in ('moderator','admin','super_admin')
  );
$$;

create or replace function public.is_tiqet_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tiqet_staff_roles r
    where r.user_id = (select auth.uid())
      and r.role in ('admin','super_admin')
  );
$$;

create or replace function public.is_tiqet_super_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tiqet_staff_roles r
    where r.user_id = (select auth.uid())
      and r.role = 'super_admin'
  );
$$;

revoke all on function public.is_tiqet_moderator() from public, anon;
revoke all on function public.is_tiqet_admin() from public, anon;
revoke all on function public.is_tiqet_super_admin() from public, anon;
grant execute on function public.is_tiqet_moderator() to authenticated, service_role;
grant execute on function public.is_tiqet_admin() to authenticated, service_role;
grant execute on function public.is_tiqet_super_admin() to authenticated, service_role;

drop policy if exists organisations_staff_read on public.organisations;
create policy organisations_staff_read on public.organisations
  for select to authenticated using (public.is_tiqet_moderator());

drop policy if exists events_staff_review_read on public.events;
create policy events_staff_review_read on public.events
  for select to authenticated using (public.is_tiqet_moderator());

drop policy if exists events_verified_org_update on public.events;
create policy events_verified_org_update on public.events
  for update to authenticated
  using (
    exists (
      select 1 from public.organisations o
      where o.id=events.organisation_id
        and o.owner_id=(select auth.uid())
        and o.status='verified'::public.organisation_status
    )
  )
  with check (
    created_by=(select auth.uid())
    and status in ('draft'::public.event_status,'submitted'::public.event_status)
    and approval_status in ('pending','rejected')
  );

create or replace function public.review_organiser_application(
  p_organisation_id uuid,p_decision text,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_org public.organisations%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_new_status public.organisation_status;
begin
  if v_actor is null then raise exception 'Authentication required'; end if;
  if not public.is_tiqet_admin() then raise exception 'Tiqet administrator permission required'; end if;
  if p_decision not in ('approve','reject','request_info') then
    raise exception 'Decision must be approve, reject or request_info';
  end if;
  if p_notes is not null and length(p_notes)>2000 then raise exception 'Review notes are too long'; end if;

  select * into v_org from public.organisations where id=p_organisation_id for update;
  if not found then raise exception 'Organiser application not found'; end if;
  if v_org.status <> 'pending'::public.organisation_status then
    raise exception 'Only pending organiser applications can be reviewed';
  end if;

  v_before := jsonb_build_object(
    'id',v_org.id,'name',v_org.name,'legal_name',v_org.legal_name,
    'owner_id',v_org.owner_id,'status',v_org.status::text,
    'verification_notes',v_org.verification_notes
  );

  v_new_status := case
    when p_decision='approve' then 'verified'::public.organisation_status
    when p_decision='reject' then 'rejected'::public.organisation_status
    else 'pending'::public.organisation_status
  end;

  update public.organisations set
    status=v_new_status,
    verification_notes=coalesce(nullif(trim(p_notes),''),verification_notes),
    reviewed_by=v_actor,reviewed_at=now(),updated_at=now()
  where id=p_organisation_id
  returning jsonb_build_object(
    'id',id,'name',name,'legal_name',legal_name,'owner_id',owner_id,
    'status',status::text,'verification_notes',verification_notes,
    'reviewed_by',reviewed_by,'reviewed_at',reviewed_at
  ) into v_after;

  insert into public.tiqet_admin_audit_log(
    actor_user_id,action,target_type,target_id,reason,before_state,after_state
  ) values (
    v_actor,'organiser_application_'||p_decision,'organisation',p_organisation_id,
    coalesce(trim(p_notes),''),v_before,v_after
  );

  return jsonb_build_object('organisation_id',p_organisation_id,'decision',p_decision,
    'status',v_new_status::text,'reviewed_at',now());
end;
$$;

create or replace function public.review_event_submission(
  p_event_id uuid,p_decision text,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_event public.events%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_new_status public.event_status;
  v_new_approval text;
begin
  if v_actor is null then raise exception 'Authentication required'; end if;
  if not public.is_tiqet_moderator() then raise exception 'Tiqet moderator permission required'; end if;
  if p_decision not in ('approve','reject','request_changes') then
    raise exception 'Decision must be approve, reject or request_changes';
  end if;
  if p_notes is not null and length(p_notes)>2000 then raise exception 'Review notes are too long'; end if;

  select * into v_event from public.events where id=p_event_id for update;
  if not found then raise exception 'Event submission not found'; end if;
  if v_event.status <> 'submitted'::public.event_status or v_event.approval_status <> 'pending' then
    raise exception 'Only pending submitted events can be reviewed';
  end if;
  if p_decision='approve' and not exists (
    select 1 from public.organisations o
    where o.id=v_event.organisation_id and o.status='verified'::public.organisation_status
  ) then
    raise exception 'The organiser must be verified before an event can be approved';
  end if;

  v_before := jsonb_build_object(
    'id',v_event.id,'title',v_event.title,'organisation_id',v_event.organisation_id,
    'status',v_event.status::text,'approval_status',v_event.approval_status
  );
  v_new_status := case when p_decision='approve'
    then 'published'::public.event_status else 'draft'::public.event_status end;
  v_new_approval := case when p_decision='approve' then 'approved' else 'rejected' end;

  update public.events set
    status=v_new_status,approval_status=v_new_approval,
    reviewed_by=v_actor,reviewed_at=now(),
    review_notes=coalesce(nullif(trim(p_notes),''),'')
  where id=p_event_id
  returning jsonb_build_object(
    'id',id,'title',title,'organisation_id',organisation_id,
    'status',status::text,'approval_status',approval_status,
    'reviewed_by',reviewed_by,'reviewed_at',reviewed_at,'review_notes',review_notes
  ) into v_after;

  insert into public.tiqet_admin_audit_log(
    actor_user_id,action,target_type,target_id,reason,before_state,after_state
  ) values (
    v_actor,'event_submission_'||p_decision,'event',p_event_id,
    coalesce(trim(p_notes),''),v_before,v_after
  );

  return jsonb_build_object('event_id',p_event_id,'decision',p_decision,
    'status',v_new_status::text,'approval_status',v_new_approval,'reviewed_at',now());
end;
$$;

create or replace function public.submit_event_for_review(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_event public.events%rowtype;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select e.* into v_event
  from public.events e
  join public.organisations o on o.id=e.organisation_id
  where e.id=p_event_id and e.created_by=v_user
    and o.owner_id=v_user and o.status='verified'::public.organisation_status
  for update of e;

  if not found then raise exception 'Verified organiser event not found'; end if;
  if v_event.status <> 'draft'::public.event_status then raise exception 'Only draft events can be submitted'; end if;
  if not exists (select 1 from public.ticket_types t where t.event_id=p_event_id) then
    raise exception 'Add at least one ticket type before submitting';
  end if;

  update public.events set
    status='submitted'::public.event_status,approval_status='pending',
    reviewed_by=null,reviewed_at=null,review_notes='',updated_at=now()
  where id=p_event_id;
  return jsonb_build_object('event_id',p_event_id,'status','submitted','approval_status','pending');
end;
$$;

create or replace function public.assign_tiqet_staff_role(
  p_user_id uuid,p_role text,p_note text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_before jsonb;
  v_after jsonb;
begin
  if v_actor is null or not public.is_tiqet_super_admin() then
    raise exception 'Tiqet super administrator permission required';
  end if;
  if p_role not in ('moderator','admin','super_admin') then raise exception 'Invalid staff role'; end if;
  if p_note is not null and length(p_note)>1000 then raise exception 'Staff note is too long'; end if;
  if not exists (select 1 from auth.users where id=p_user_id) then raise exception 'User not found'; end if;

  select jsonb_build_object('role',role,'note',note) into v_before
  from public.tiqet_staff_roles where user_id=p_user_id;

  insert into public.tiqet_staff_roles(user_id,role,granted_by,note,updated_at)
  values(p_user_id,p_role,v_actor,coalesce(trim(p_note),''),now())
  on conflict(user_id) do update set
    role=excluded.role,granted_by=excluded.granted_by,note=excluded.note,updated_at=now();

  select jsonb_build_object('role',role,'note',note) into v_after
  from public.tiqet_staff_roles where user_id=p_user_id;

  insert into public.tiqet_admin_audit_log(
    actor_user_id,action,target_type,target_id,reason,before_state,after_state
  ) values (v_actor,'staff_role_assigned','user',p_user_id,coalesce(trim(p_note),''),v_before,v_after);
  return jsonb_build_object('user_id',p_user_id,'role',p_role,'assigned',true);
end;
$$;

create or replace function public.revoke_tiqet_staff_role(p_user_id uuid,p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_before jsonb;
begin
  if v_actor is null or not public.is_tiqet_super_admin() then
    raise exception 'Tiqet super administrator permission required';
  end if;
  if p_user_id=v_actor then raise exception 'You cannot revoke your own staff role'; end if;
  if p_note is not null and length(p_note)>1000 then raise exception 'Staff note is too long'; end if;

  select jsonb_build_object('role',role,'note',note) into v_before
  from public.tiqet_staff_roles where user_id=p_user_id for update;
  if v_before is null then return jsonb_build_object('user_id',p_user_id,'revoked',false); end if;
  if v_before->>'role'='super_admin' and (
    select count(*) from public.tiqet_staff_roles where role='super_admin'
  ) <= 1 then raise exception 'Cannot revoke the last super administrator'; end if;

  delete from public.tiqet_staff_roles where user_id=p_user_id;
  insert into public.tiqet_admin_audit_log(
    actor_user_id,action,target_type,target_id,reason,before_state,after_state
  ) values (v_actor,'staff_role_revoked','user',p_user_id,coalesce(trim(p_note),''),v_before,null);
  return jsonb_build_object('user_id',p_user_id,'revoked',true);
end;
$$;

create or replace function public.get_tiqet_control_overview()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_moderator() then
    raise exception 'Tiqet staff permission required';
  end if;
  select jsonb_build_object(
    'pending_events',(select count(*) from public.events where status='submitted'::public.event_status and approval_status='pending'),
    'published_events',(select count(*) from public.events where status='published'::public.event_status and approval_status='approved'),
    'pending_organisers',case when public.is_tiqet_admin()
      then (select count(*) from public.organisations where status='pending'::public.organisation_status) else null end,
    'verified_organisers',case when public.is_tiqet_admin()
      then (select count(*) from public.organisations where status='verified'::public.organisation_status) else null end,
    'registered_users',(select count(*) from auth.users),
    'admin_access',public.is_tiqet_admin(),
    'super_admin_access',public.is_tiqet_super_admin()
  ) into v_result;
  return v_result;
end;
$$;

-- Bootstrap the first super administrator separately for each deployment.
-- Do not put a founder email or user UUID in a public source-control migration.

revoke all on function public.review_organiser_application(uuid,text,text) from public,anon;
revoke all on function public.review_event_submission(uuid,text,text) from public,anon;
revoke all on function public.submit_event_for_review(uuid) from public,anon;
revoke all on function public.assign_tiqet_staff_role(uuid,text,text) from public,anon,authenticated;
revoke all on function public.revoke_tiqet_staff_role(uuid,text) from public,anon,authenticated;
revoke all on function public.get_tiqet_control_overview() from public,anon;
grant execute on function public.review_organiser_application(uuid,text,text) to authenticated,service_role;
grant execute on function public.review_event_submission(uuid,text,text) to authenticated,service_role;
grant execute on function public.submit_event_for_review(uuid) to authenticated,service_role;
grant execute on function public.get_tiqet_control_overview() to authenticated,service_role;

commit;
