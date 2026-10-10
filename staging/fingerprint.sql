-- Structural fingerprint of LabGram objects (no user data). Run on staging and production, then diff.
select json_agg(json_build_object('k', k, 'h', h) order by k) from (
  select 'col:'||table_name||'.'||column_name k, md5(data_type||'|'||is_nullable||'|'||coalesce(column_default,'')) h
    from information_schema.columns where table_schema='public' and table_name like 'lg\_%'
  union all
  select 'pol:'||tablename||'.'||policyname, md5(cmd||'|'||permissive||'|'||roles::text||'|'||coalesce(qual,'')||'|'||coalesce(with_check,''))
    from pg_policies where (schemaname='public' and tablename like 'lg\_%') or policyname like 'lg\_%' or policyname like 'legacy\_%'
  union all
  select 'con:'||conrelid::regclass::text||'.'||conname, md5(pg_get_constraintdef(oid))
    from pg_constraint where conrelid::regclass::text like 'lg\_%' or conrelid::regclass::text like 'public.lg\_%'
  union all
  select 'trg:'||c.relname||'.'||t.tgname, md5(p.proname||'|'||t.tgtype::text)
    from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_proc p on p.oid=t.tgfoid
    where not t.tgisinternal and (t.tgname like 'lg\_%')
  union all
  select 'fn:'||p.proname, md5(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g'))
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and (p.proname like 'lg\_%' or p.proname='handle_new_user')
  union all
  select 'idx:'||indexname, md5(regexp_replace(indexdef, '\s+', ' ', 'g'))
    from pg_indexes where schemaname='public' and tablename like 'lg\_%'
  union all
  select 'grant:'||table_name||'.'||grantee, md5(string_agg(privilege_type, ',' order by privilege_type))
    from information_schema.role_table_grants
    where table_schema='public' and grantee in ('anon','authenticated') group by table_name, grantee
) x;
