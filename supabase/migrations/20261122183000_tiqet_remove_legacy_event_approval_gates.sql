-- In launch mode, published state is the sole event availability gate.
-- A moderator review action moves a published event to submitted, which blocks
-- discovery, checkout and organiser edits without the obsolete approval flag.
begin;

do $migration$
declare
  patch record;
  signature regprocedure;
  definition text;
begin
  for patch in
    select * from (values
      (
        'public.create_order_hold(uuid,integer,uuid)',
        $old$or v_event.approval_status <> 'approved' then$old$,
        $new$then$new$
      ),
      (
        'public.claim_free_tickets(uuid,integer)',
        $old$or v_event.approval_status <> 'approved' then$old$,
        $new$then$new$
      ),
      (
        'public.flag_tiqet_event_for_review(uuid,text)',
        $old$or v_event.approval_status <> 'approved' then$old$,
        $new$then$new$
      ),
      (
        'public.get_tiqet_control_overview()',
        $old$'published_events',(select count(*) from public.events where status='published'::public.event_status and approval_status='approved'),$old$,
        $new$'published_events',(select count(*) from public.events where status='published'::public.event_status),$new$
      ),
      (
        'public.submit_event_for_review(uuid)',
        $old$if v_event.status not in ('draft'::public.event_status, 'submitted'::public.event_status) then$old$,
        $new$if v_event.status <> 'draft'::public.event_status then$new$
      )
    ) as patches(signature_text, old_text, new_text)
  loop
    signature := to_regprocedure(patch.signature_text);
    if signature is null then
      raise exception 'Required Tiqet function is missing: %', patch.signature_text;
    end if;

    definition := pg_get_functiondef(signature);
    if position(patch.old_text in definition) = 0 then
      raise exception 'Expected source fragment was not found in %', patch.signature_text;
    end if;

    definition := replace(definition, patch.old_text, patch.new_text);
    execute definition;
  end loop;
end
$migration$;

notify pgrst, 'reload schema';
commit;
