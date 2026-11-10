-- Tiqet Control: restricted staff directory and audit-log reads.

begin;

grant execute on function public.assign_tiqet_staff_role(uuid,text,text) to authenticated;
grant execute on function public.revoke_tiqet_staff_role(uuid,text) to authenticated;

create or replace function public.get_tiqet_staff_directory()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_super_admin() then
    raise exception 'Tiqet super administrator permission required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',r.user_id,'email',u.email,'full_name',coalesce(p.full_name,''),
    'role',r.role,'note',r.note,'granted_by',r.granted_by,
    'created_at',r.created_at,'updated_at',r.updated_at
  ) order by r.created_at),'[]'::jsonb)
  into v_rows
  from public.tiqet_staff_roles r
  join auth.users u on u.id=r.user_id
  left join public.profiles p on p.id=r.user_id;

  return jsonb_build_object('staff',v_rows);
end;
$$;
revoke all on function public.get_tiqet_staff_directory() from public,anon;
grant execute on function public.get_tiqet_staff_directory() to authenticated,service_role;

create or replace function public.get_tiqet_admin_audit_log(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Limit must be from 1 to 100';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'actor_user_id',a.actor_user_id,'actor_email',u.email,
    'action',a.action,'target_type',a.target_type,'target_id',a.target_id,
    'reason',a.reason,'before_state',a.before_state,
    'after_state',a.after_state,'created_at',a.created_at
  ) order by a.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select * from public.tiqet_admin_audit_log
    order by created_at desc limit p_limit
  ) a
  left join auth.users u on u.id=a.actor_user_id;

  return jsonb_build_object('entries',v_rows);
end;
$$;
revoke all on function public.get_tiqet_admin_audit_log(integer) from public,anon;
grant execute on function public.get_tiqet_admin_audit_log(integer) to authenticated,service_role;

create or replace function public.search_tiqet_users(p_query text,p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_super_admin() then
    raise exception 'Tiqet super administrator permission required';
  end if;
  if p_query is null or length(trim(p_query))<3 or length(trim(p_query))>120 then
    raise exception 'Search term must be between 3 and 120 characters';
  end if;
  if p_limit is null or p_limit not between 1 and 30 then
    raise exception 'Limit must be from 1 to 30';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',u.id,'email',u.email,'full_name',coalesce(p.full_name,''),
    'created_at',u.created_at,
    'staff_role',r.role
  ) order by u.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select id,email,created_at
    from auth.users
    where email ilike '%'||trim(p_query)||'%'
    order by created_at desc
    limit p_limit
  ) u
  left join public.profiles p on p.id=u.id
  left join public.tiqet_staff_roles r on r.user_id=u.id;

  return jsonb_build_object('users',v_rows);
end;
$$;
revoke all on function public.search_tiqet_users(text,integer) from public,anon;
grant execute on function public.search_tiqet_users(text,integer) to authenticated,service_role;

commit;
