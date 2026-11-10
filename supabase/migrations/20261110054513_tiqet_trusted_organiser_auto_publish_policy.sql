-- Tiqet Control: trust-based organizer publishing and event review overrides.
-- Trusted status and review flags are private server-managed records; clients cannot edit them.

begin;

create table if not exists public.tiqet_trusted_organisers (
  organisation_id uuid primary key references public.organisations(id) on delete cascade,
  auto_publish_enabled boolean not null default true,
  granted_by uuid not null references auth.users(id) on delete restrict,
  reason text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.tiqet_trusted_organisers enable row level security;
revoke all on public.tiqet_trusted_organisers from public,anon,authenticated;
grant all on public.tiqet_trusted_organisers to service_role;

create table if not exists public.tiqet_event_review_flags (
  event_id uuid primary key references public.events(id) on delete cascade,
  is_active boolean not null default true,
  flagged_by uuid not null references auth.users(id) on delete restrict,
  reason text not null,
  created_at timestamptz not null default now(),
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz
);
create index if not exists tiqet_event_review_flags_active_idx
  on public.tiqet_event_review_flags(is_active,created_at desc);
alter table public.tiqet_event_review_flags enable row level security;
revoke all on public.tiqet_event_review_flags from public,anon,authenticated;
grant all on public.tiqet_event_review_flags to service_role;

create or replace function public.get_tiqet_verified_organisers()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',o.id,'name',o.name,'legal_name',o.legal_name,
    'contact_phone',o.contact_phone,'owner_id',o.owner_id,
    'status',o.status::text,'created_at',o.created_at,
    'auto_publish_enabled',coalesce(t.auto_publish_enabled,false),
    'trusted_since',t.created_at,'trust_reason',coalesce(t.reason,'')
  ) order by o.created_at desc),'[]'::jsonb)
  into v_rows
  from public.organisations o
  left join public.tiqet_trusted_organisers t on t.organisation_id=o.id and t.auto_publish_enabled
  where o.status='verified'::public.organisation_status;
  return jsonb_build_object('organisers',v_rows);
end;
$$;

create or replace function public.set_organiser_auto_publish(
  p_organisation_id uuid,p_enabled boolean,p_reason text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_org public.organisations%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  if v_actor is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_organisation_id is null or p_enabled is null then raise exception 'Organisation and publish setting are required'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 or length(trim(p_reason)) > 500 then
    raise exception 'Provide a reason between 5 and 500 characters';
  end if;
  select * into v_org from public.organisations where id=p_organisation_id for update;
  if not found then raise exception 'Organiser not found'; end if;
  if v_org.status <> 'verified'::public.organisation_status then
    raise exception 'Only verified organisers can be trusted for auto-publishing';
  end if;
  select jsonb_build_object('auto_publish_enabled',auto_publish_enabled,'reason',reason)
    into v_before from public.tiqet_trusted_organisers where organisation_id=p_organisation_id;

  if p_enabled then
    insert into public.tiqet_trusted_organisers(organisation_id,auto_publish_enabled,granted_by,reason,updated_at)
    values(p_organisation_id,true,v_actor,trim(p_reason),now())
    on conflict(organisation_id) do update set
      auto_publish_enabled=true,granted_by=v_actor,reason=trim(p_reason),updated_at=now();
  else
    delete from public.tiqet_trusted_organisers where organisation_id=p_organisation_id;
  end if;

  if p_enabled then v_after:=jsonb_build_object('auto_publish_enabled',true,'reason',trim(p_reason));
  else v_after:=jsonb_build_object('auto_publish_enabled',false,'reason',trim(p_reason)); end if;

  insert into public.tiqet_admin_audit_log(actor_user_id,action,target_type,target_id,reason,before_state,after_state)
  values(v_actor,case when p_enabled then 'organiser_auto_publish_enabled' else 'organiser_auto_publish_disabled' end,
    'organisation',p_organisation_id,trim(p_reason),v_before,v_after);

  return jsonb_build_object('organisation_id',p_organisation_id,'auto_publish_enabled',p_enabled,'reason',trim(p_reason));
end;
$$;

create or replace function public.flag_tiqet_event_for_review(p_event_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_event public.events%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  if v_actor is null or not public.is_tiqet_moderator() then raise exception 'Tiqet moderator permission required'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 or length(trim(p_reason)) > 1000 then
    raise exception 'Provide a reason between 5 and 1000 characters';
  end if;
  select * into v_event from public.events where id=p_event_id for update;
  if not found then raise exception 'Event not found'; end if;
  if v_event.status <> 'published'::public.event_status or v_event.approval_status <> 'approved' then
    raise exception 'Only published, approved events can be flagged for review';
  end if;
  v_before:=jsonb_build_object('status',v_event.status::text,'approval_status',v_event.approval_status);

  insert into public.tiqet_event_review_flags(event_id,is_active,flagged_by,reason,created_at,resolved_by,resolved_at)
  values(p_event_id,true,v_actor,trim(p_reason),now(),null,null)
  on conflict(event_id) do update set
    is_active=true,flagged_by=v_actor,reason=trim(p_reason),
    created_at=now(),resolved_by=null,resolved_at=null;

  update public.events set status='submitted'::public.event_status,approval_status='pending',
    reviewed_by=null,reviewed_at=null,review_notes=trim(p_reason),updated_at=now()
  where id=p_event_id
  returning jsonb_build_object('status',status::text,'approval_status',approval_status,'review_notes',review_notes)
  into v_after;

  insert into public.tiqet_admin_audit_log(actor_user_id,action,target_type,target_id,reason,before_state,after_state)
  values(v_actor,'published_event_flagged_for_review','event',p_event_id,trim(p_reason),v_before,v_after);

  return jsonb_build_object('event_id',p_event_id,'status','submitted','approval_status','pending','flagged',true);
end;
$$;

create or replace function public.submit_event_for_review(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_event public.events%rowtype;
  v_auto_publish boolean := false;
  v_is_flagged boolean := false;
  v_new_status public.event_status;
  v_new_approval text;
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

  select coalesce(t.auto_publish_enabled,false) into v_auto_publish
  from public.tiqet_trusted_organisers t where t.organisation_id=v_event.organisation_id;
  v_auto_publish:=coalesce(v_auto_publish,false);
  select coalesce(f.is_active,false) into v_is_flagged
  from public.tiqet_event_review_flags f where f.event_id=p_event_id;
  v_is_flagged:=coalesce(v_is_flagged,false);

  if v_auto_publish and not v_is_flagged then
    v_new_status:='published'::public.event_status;
    v_new_approval:='approved';
  else
    v_new_status:='submitted'::public.event_status;
    v_new_approval:='pending';
  end if;

  update public.events set
    status=v_new_status,approval_status=v_new_approval,
    reviewed_by=null,reviewed_at=null,
    review_notes=case when v_is_flagged then review_notes else '' end,
    updated_at=now()
  where id=p_event_id;

  if v_new_status='published'::public.event_status then
    insert into public.tiqet_admin_audit_log(actor_user_id,action,target_type,target_id,reason,after_state)
    values(v_user,'trusted_organiser_event_auto_published','event',p_event_id,
      'Trusted organiser auto-publish policy',
      jsonb_build_object('organisation_id',v_event.organisation_id,'status','published'));
  end if;

  return jsonb_build_object('event_id',p_event_id,'status',v_new_status::text,
    'approval_status',v_new_approval,'automatically_published',v_new_status='published'::public.event_status);
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
  if p_decision not in ('approve','reject','request_changes') then raise exception 'Invalid event decision'; end if;
  if p_notes is not null and length(p_notes)>2000 then raise exception 'Review notes are too long'; end if;

  select * into v_event from public.events where id=p_event_id for update;
  if not found then raise exception 'Event submission not found'; end if;
  if v_event.status <> 'submitted'::public.event_status or v_event.approval_status <> 'pending' then
    raise exception 'Only pending submitted events can be reviewed';
  end if;
  if p_decision='approve' and not exists (
    select 1 from public.organisations o where o.id=v_event.organisation_id
      and o.status='verified'::public.organisation_status
  ) then raise exception 'The organiser must be verified before an event can be approved'; end if;

  v_before:=jsonb_build_object('id',v_event.id,'title',v_event.title,'organisation_id',v_event.organisation_id,
    'status',v_event.status::text,'approval_status',v_event.approval_status);

  if p_decision='approve' then
    v_new_status:='published'::public.event_status;
    v_new_approval:='approved';
    update public.tiqet_event_review_flags set is_active=false,resolved_by=v_actor,resolved_at=now()
    where event_id=p_event_id;
  else
    v_new_status:='draft'::public.event_status;
    v_new_approval:='rejected';
    insert into public.tiqet_event_review_flags(event_id,is_active,flagged_by,reason)
    values(p_event_id,true,v_actor,coalesce(nullif(trim(p_notes),''),'Review changes required'))
    on conflict(event_id) do update set is_active=true,flagged_by=v_actor,
      reason=coalesce(nullif(trim(p_notes),''),'Review changes required'),
      created_at=now(),resolved_by=null,resolved_at=null;
  end if;

  update public.events set status=v_new_status,approval_status=v_new_approval,
    reviewed_by=v_actor,reviewed_at=now(),review_notes=coalesce(nullif(trim(p_notes),''),'')
  where id=p_event_id
  returning jsonb_build_object('id',id,'title',title,'organisation_id',organisation_id,
    'status',status::text,'approval_status',approval_status,'reviewed_by',reviewed_by,
    'reviewed_at',reviewed_at,'review_notes',review_notes) into v_after;

  insert into public.tiqet_admin_audit_log(actor_user_id,action,target_type,target_id,reason,before_state,after_state)
  values(v_actor,'event_submission_'||p_decision,'event',p_event_id,coalesce(trim(p_notes),''),v_before,v_after);

  return jsonb_build_object('event_id',p_event_id,'decision',p_decision,
    'status',v_new_status::text,'approval_status',v_new_approval,'reviewed_at',now());
end;
$$;

revoke all on function public.get_tiqet_verified_organisers() from public,anon;
revoke all on function public.set_organiser_auto_publish(uuid,boolean,text) from public,anon;
revoke all on function public.flag_tiqet_event_for_review(uuid,text) from public,anon;
grant execute on function public.get_tiqet_verified_organisers() to authenticated,service_role;
grant execute on function public.set_organiser_auto_publish(uuid,boolean,text) to authenticated,service_role;
grant execute on function public.flag_tiqet_event_for_review(uuid,text) to authenticated,service_role;

commit;
