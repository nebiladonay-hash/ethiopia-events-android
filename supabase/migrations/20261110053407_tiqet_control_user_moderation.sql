-- Tiqet Control: audited account suspension/restoration workflow.
-- Actual Auth ban/restore is executed by the JWT-protected service-role Edge Function.

begin;

create table if not exists public.tiqet_user_moderation_log (
  id bigint generated always as identity primary key,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  target_user_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('suspend','restore')),
  ban_duration text check (ban_duration is null or ban_duration in ('24h','168h','720h')),
  reason text not null,
  status text not null default 'pending' check (status in ('pending','completed','failed')),
  error_message text not null default '',
  banned_until timestamptz,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists tiqet_user_moderation_target_idx
  on public.tiqet_user_moderation_log(target_user_id,created_at desc);
create index if not exists tiqet_user_moderation_actor_idx
  on public.tiqet_user_moderation_log(actor_user_id,created_at desc);
alter table public.tiqet_user_moderation_log enable row level security;
revoke all on public.tiqet_user_moderation_log from public,anon,authenticated;
grant all on public.tiqet_user_moderation_log to service_role;

create or replace function public.search_tiqet_users(p_query text,p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_query is null or length(trim(p_query))<3 or length(trim(p_query))>120 then
    raise exception 'Search term must be between 3 and 120 characters';
  end if;
  if p_limit is null or p_limit not between 1 and 30 then
    raise exception 'Limit must be from 1 to 30';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',u.id,'email',u.email,'full_name',coalesce(p.full_name,''),
    'created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
    'banned_until',u.banned_until,'staff_role',r.role
  ) order by u.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select id,email,created_at,last_sign_in_at,banned_until
    from auth.users
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

create or replace function public.get_tiqet_user_moderation_history(
  p_user_id uuid,
  p_limit integer default 20
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_user_id is null then raise exception 'User id is required'; end if;
  if p_limit is null or p_limit not between 1 and 50 then
    raise exception 'Limit must be from 1 to 50';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'actor_user_id',m.actor_user_id,'actor_email',a.email,
    'target_user_id',m.target_user_id,'target_email',t.email,
    'action',m.action,'ban_duration',m.ban_duration,'reason',m.reason,
    'status',m.status,'error_message',m.error_message,
    'banned_until',m.banned_until,'created_at',m.created_at,'completed_at',m.completed_at
  ) order by m.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select * from public.tiqet_user_moderation_log
    where target_user_id=p_user_id
    order by created_at desc limit p_limit
  ) m
  left join auth.users a on a.id=m.actor_user_id
  left join auth.users t on t.id=m.target_user_id;

  return jsonb_build_object('history',v_rows);
end;
$$;
revoke all on function public.get_tiqet_user_moderation_history(uuid,integer) from public,anon;
grant execute on function public.get_tiqet_user_moderation_history(uuid,integer) to authenticated,service_role;

commit;
