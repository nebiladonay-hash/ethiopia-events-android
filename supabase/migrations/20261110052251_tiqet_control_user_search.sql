-- Tiqet Control: restricted user lookup for super administrators only.
begin;

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
    'created_at',u.created_at,'staff_role',r.role
  ) order by u.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select id,email,created_at from auth.users
    where email ilike '%'||trim(p_query)||'%'
    order by created_at desc limit p_limit
  ) u
  left join public.profiles p on p.id=u.id
  left join public.tiqet_staff_roles r on r.user_id=u.id;

  return jsonb_build_object('users',v_rows);
end;
$$;
revoke all on function public.search_tiqet_users(text,integer) from public,anon;
grant execute on function public.search_tiqet_users(text,integer) to authenticated,service_role;

commit;
