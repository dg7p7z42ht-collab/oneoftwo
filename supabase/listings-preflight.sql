-- Production preflight. Read-only, no row-level listing data.
begin read only;
set local statement_timeout = '15s';

select section, details
from (
  select 1 as position, 'tables_and_rls' as section, coalesce(jsonb_agg(
    jsonb_build_object('table', n.nspname || '.' || c.relname, 'kind', c.relkind,
      'rls', c.relrowsecurity, 'forced', c.relforcerowsecurity,
      'estimated_rows', greatest(c.reltuples, 0))
    order by n.nspname, c.relname), '[]'::jsonb) as details
  from pg_class as c join pg_namespace as n on n.oid = c.relnamespace
  where (n.nspname, c.relname) in (('public','listings'),('storage','buckets'),('storage','objects'))

  union all
  select 2, 'listings_columns', coalesce(jsonb_agg(
    jsonb_build_object('name', column_name, 'type', data_type, 'udt', udt_name,
      'nullable', is_nullable, 'default', column_default, 'identity', is_identity)
    order by ordinal_position), '[]'::jsonb)
  from information_schema.columns where table_schema = 'public' and table_name = 'listings'

  union all
  select 3, 'listings_constraints_and_indexes', coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  from (
    select conname as name, pg_get_constraintdef(oid) as definition from pg_constraint
    where conrelid = to_regclass('public.listings')
    union all
    select indexname, indexdef from pg_indexes where schemaname = 'public' and tablename = 'listings'
  ) as x

  union all
  select 4, 'policies', coalesce(jsonb_agg(to_jsonb(p) order by schemaname, tablename, policyname), '[]'::jsonb)
  from pg_policies as p
  where (schemaname, tablename) in (('public','listings'),('storage','objects'),('storage','buckets'))

  union all
  select 5, 'listings_grants', coalesce(jsonb_agg(jsonb_build_object(
    'role', case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end,
    'privilege', a.privilege_type) order by a.grantee, a.privilege_type), '[]'::jsonb)
  from pg_class as c, lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) as a
  where c.oid = to_regclass('public.listings')

  union all
  select 6, 'listings_column_grants', coalesce(jsonb_agg(jsonb_build_object(
    'column', c.attname, 'role', case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end,
    'privilege', a.privilege_type) order by c.attnum, a.grantee, a.privilege_type), '[]'::jsonb)
  from pg_attribute as c, lateral aclexplode(c.attacl) as a
  where c.attrelid = to_regclass('public.listings') and c.attnum > 0 and not c.attisdropped

  union all
  select 7, 'listings_triggers', coalesce(jsonb_agg(jsonb_build_object(
    'trigger', tgname, 'enabled', tgenabled, 'definition', pg_get_triggerdef(oid)) order by tgname), '[]'::jsonb)
  from pg_trigger
  where tgrelid = to_regclass('public.listings') and not tgisinternal

  union all
  select 8, 'dependent_views', coalesce(jsonb_agg(distinct jsonb_build_object(
    'view', n.nspname || '.' || c.relname, 'options', c.reloptions)), '[]'::jsonb)
  from pg_depend as d
  join pg_rewrite as r on d.classid = 'pg_rewrite'::regclass and r.oid = d.objid
  join pg_class as c on c.oid = r.ev_class
  join pg_namespace as n on n.oid = c.relnamespace
  where d.refclassid = 'pg_class'::regclass and d.refobjid = to_regclass('public.listings')
    and c.relkind in ('v','m')

  union all
  select 9, 'listing_images_bucket', coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'public', b.public, 'size_limit', b.file_size_limit, 'mime_types', b.allowed_mime_types,
    'objects', (select count(*) from storage.objects as o where o.bucket_id = b.id))), '[]'::jsonb)
  from storage.buckets as b where b.id = 'listing-images'
) as report
order by position;

rollback;
