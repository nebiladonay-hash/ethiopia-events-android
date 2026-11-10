-- Tiqet Control: moderator-only listing of currently published events for safety review.

begin;

create or replace function public.get_tiqet_published_events_for_review(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_moderator() then
    raise exception 'Tiqet moderator permission required';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Limit must be from 1 to 100';
  end if;

  select coalesce(jsonb_agg(x.item order by x.starts_at asc),'[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id',e.id,'title',e.title,'description',e.description,'category',e.category,
      'starts_at',e.starts_at,'venue_name',e.venue_name,'city',e.city,
      'image_url',e.image_url,'organisation_id',e.organisation_id,
      'organisation_name',o.name,'created_at',e.created_at
    ) item,e.starts_at
    from public.events e
    join public.organisations o on o.id=e.organisation_id
    where e.status='published'::public.event_status and e.approval_status='approved'
    order by e.starts_at asc
    limit p_limit
  ) x;

  return jsonb_build_object('events',v_rows);
end;
$$;

revoke all on function public.get_tiqet_published_events_for_review(integer) from public,anon;
grant execute on function public.get_tiqet_published_events_for_review(integer) to authenticated,service_role;

commit;
