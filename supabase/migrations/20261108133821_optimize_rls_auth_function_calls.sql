do $migration$
declare
  policy_row record;
  policy_sql text;
  role_list text;
begin
  for policy_row in
    select *
    from pg_policies
    where schemaname = 'public'
      and (
        (qual is not null and qual like '%auth.uid()%')
        or (with_check is not null and with_check like '%auth.uid()%')
      )
    order by tablename, policyname
  loop
    role_list := array_to_string(policy_row.roles, ', ');
    execute format('drop policy %I on %I.%I',policy_row.policyname,policy_row.schemaname,policy_row.tablename);
    policy_sql := format(
      'create policy %I on %I.%I as %s for %s to %s',
      policy_row.policyname,policy_row.schemaname,policy_row.tablename,
      lower(policy_row.permissive),lower(policy_row.cmd),role_list
    );
    if policy_row.qual is not null then
      policy_sql := policy_sql || format(' using (%s)',replace(policy_row.qual,'auth.uid()','(select auth.uid())'));
    end if;
    if policy_row.with_check is not null then
      policy_sql := policy_sql || format(' with check (%s)',replace(policy_row.with_check,'auth.uid()','(select auth.uid())'));
    end if;
    execute policy_sql;
  end loop;
end
$migration$;
