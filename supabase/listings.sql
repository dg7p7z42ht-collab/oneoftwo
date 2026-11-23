-- Phase 1: prepare schema and pause writes. Leave the bucket visibility unchanged.
-- Review the read-only preflight and take backups before any production use.
begin;
set local lock_timeout = '5s';

create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text not null default '',
  category text not null check (btrim(category) <> ''),
  listing_type text not null check (listing_type in ('available', 'wanted')),
  publication_status text not null default 'draft' check (publication_status in ('draft', 'published')),
  created_at timestamptz not null default now()
);

alter table public.listings
  add column if not exists image_url text,
  add column if not exists image_path text,
  add column if not exists client_request_id uuid;

-- Guard the types and defaults the editor relies on. Known legacy fields keep
-- their existing types and values, but new inserts must be allowed to omit them.
do $$
begin
  if exists (
    select 1
    from (values
      ('id', array['uuid','smallint','integer','bigint']),
      ('user_id', array['uuid']),
      ('title', array['text','character varying']),
      ('description', array['text','character varying']),
      ('category', array['text','character varying']),
      ('listing_type', array['text','character varying']),
      ('publication_status', array['text','character varying']),
      ('created_at', array['timestamp with time zone']),
      ('image_url', array['text','character varying']),
      ('image_path', array['text','character varying']),
      ('client_request_id', array['uuid'])
    ) as expected(name, types)
    left join information_schema.columns as c
      on c.table_schema = 'public' and c.table_name = 'listings' and c.column_name = expected.name
    where c.data_type is null or not (c.data_type = any(expected.types))
      or c.is_generated <> 'NEVER'
      or (c.column_name <> 'id' and c.is_identity = 'YES')
  ) or not exists (
    select 1
    from pg_index as i
    join pg_attribute as a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
    where i.indrelid = 'public.listings'::regclass and i.indisprimary
      and i.indnkeyatts = 1 and a.attname = 'id'
  ) or exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'listings'
      and column_name in ('id', 'created_at')
      and column_default is null and is_identity <> 'YES'
  ) then
    raise exception 'Incompatible listings column type, primary key or insert default. Review the schema.';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'listings'
      and column_name not in (
        'id', 'user_id', 'title', 'description', 'category', 'listing_type',
        'publication_status', 'created_at', 'image_url', 'image_path', 'client_request_id'
      )
      and (
        column_name not in (
          'location', 'item_have', 'item_wanted', 'brand', 'model', 'color', 'size',
          'have_side', 'wanted_side'
        )
        or (is_nullable = 'NO' and column_default is null
            and is_identity <> 'YES' and is_generated = 'NEVER')
      )
  ) then
    raise exception 'Unknown or required legacy listings column. Review the insert contract and privacy.';
  end if;
  if exists (
    select 1 from public.listings as l
    where l.user_id is null
      or not exists (select 1 from auth.users as u where u.id = l.user_id)
      or l.listing_type is null or l.listing_type not in ('available', 'wanted')
      or l.publication_status is null or l.publication_status not in ('draft', 'published')
  ) then
    raise exception 'Existing listings have unexpected owners, types or status. Review without changing the data.';
  end if;
end
$$;

alter table public.listings alter column client_request_id set default gen_random_uuid();
update public.listings set client_request_id = gen_random_uuid() where client_request_id is null;
alter table public.listings alter column client_request_id set not null;

create unique index if not exists oneoftwo_listings_client_request_id_idx
  on public.listings (client_request_id);
create index if not exists oneoftwo_listings_user_idx
  on public.listings (user_id, created_at desc);
create index if not exists oneoftwo_listings_category_idx
  on public.listings (category, created_at desc) where publication_status = 'published';
create index if not exists oneoftwo_listings_image_idx
  on public.listings (image_path) where image_path is not null;

alter table public.listings drop constraint if exists oneoftwo_listings_image_path_owner;
alter table public.listings add constraint oneoftwo_listings_image_path_owner check (
  image_path is null or (
    user_id is not null and image_path ~ ('^' || user_id::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$')
  )
) not valid;
alter table public.listings validate constraint oneoftwo_listings_image_path_owner;

-- Fresh installations begin private. For existing buckets, keep the old
-- public URLs working until the new reader is deployed.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-images', 'listing-images', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create table if not exists public.oneoftwo_listing_rollout (
  singleton boolean primary key default true check (singleton),
  cutover_complete boolean not null default false,
  writes_enabled boolean not null default false
);
alter table public.oneoftwo_listing_rollout enable row level security;
revoke all on public.oneoftwo_listing_rollout from public, anon, authenticated;
insert into public.oneoftwo_listing_rollout (singleton, writes_enabled)
values (true, false)
on conflict (singleton) do update set writes_enabled = false, cutover_complete = false;

create or replace function public.oneoftwo_listing_writes_enabled()
returns boolean
language sql
stable security definer
set search_path = ''
as $$
  select coalesce((
    select r.writes_enabled and r.cutover_complete and not b.public
    from public.oneoftwo_listing_rollout as r
    cross join storage.buckets as b
    where r.singleton and b.id = 'listing-images'
  ), false);
$$;
revoke all on function public.oneoftwo_listing_writes_enabled() from public;
grant execute on function public.oneoftwo_listing_writes_enabled() to anon, authenticated;

-- RLS filters rows. Column permissions also protect legacy data and ownership
-- metadata, including on published rows accessible to signed-in visitors.
alter table public.listings enable row level security;
revoke all privileges on table public.listings from public, anon, authenticated;
do $$
declare
  column_names text;
begin
  select string_agg(format('%I', column_name), ', ')
  into column_names
  from information_schema.columns
  where table_schema = 'public' and table_name = 'listings';
  execute format('revoke all privileges (%s) on table public.listings from public, anon, authenticated', column_names);
end
$$;
grant select (id, title, description, category, listing_type, publication_status, created_at,
              image_url, image_path) on public.listings to anon, authenticated;
grant insert (user_id, client_request_id, title, description, category, listing_type,
              publication_status, image_url, image_path) on public.listings to authenticated;
grant update (title, description, category, listing_type, publication_status,
              image_url, image_path) on public.listings to authenticated;
grant delete on public.listings to authenticated;

-- Expose only the signed-in owner's matching records without making ownership
-- or request IDs queryable on the public table endpoint.
create or replace function public.oneoftwo_listing_for_edit(request_id uuid)
returns table (
  id text, title text, description text, category text, listing_type text,
  publication_status text, image_path text, image_url text
)
language sql
stable security definer
set search_path = ''
as $$
  select l.id::text, l.title::text, l.description::text, l.category::text, l.listing_type::text,
         l.publication_status::text, l.image_path::text, l.image_url::text
  from public.listings as l
  where l.user_id = (select auth.uid()) and l.client_request_id = $1;
$$;

create or replace function public.oneoftwo_listing_drafts()
returns table (client_request_id uuid, title text)
language sql
stable security definer
set search_path = ''
as $$
  select l.client_request_id, l.title::text
  from public.listings as l
  where l.user_id = (select auth.uid()) and l.publication_status = 'draft'
  order by l.created_at desc;
$$;

revoke all on function public.oneoftwo_listing_for_edit(uuid) from public, anon, authenticated;
revoke all on function public.oneoftwo_listing_drafts() from public, anon, authenticated;
grant execute on function public.oneoftwo_listing_for_edit(uuid) to authenticated;
grant execute on function public.oneoftwo_listing_drafts() to authenticated;

-- Abort on unexpected effective rights, including from inherited role grants.
do $$
declare
  browser_role text;
  privilege_name text;
  listing_column text;
  permitted boolean;
  readable constant text[] := array[
    'id', 'title', 'description', 'category', 'listing_type', 'publication_status',
    'created_at', 'image_url', 'image_path'
  ];
  editable constant text[] := array[
    'title', 'description', 'category', 'listing_type', 'publication_status', 'image_url', 'image_path'
  ];
begin
  foreach browser_role in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = browser_role and (rolsuper or rolbypassrls))
      or pg_has_role(browser_role, (
        select pg_get_userbyid(relowner) from pg_class where oid = 'public.listings'::regclass
      ), 'MEMBER') then
      raise exception 'Unsafe role membership for %. Review grants before deployment.', browser_role;
    end if;
    foreach privilege_name in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] loop
      permitted := browser_role = 'authenticated' and privilege_name = 'DELETE';
      if has_table_privilege(browser_role, 'public.listings', privilege_name) is distinct from permitted then
        raise exception 'Unexpected effective % privilege on listings for %. Review inherited grants.',
          privilege_name, browser_role;
      end if;
    end loop;
    if current_setting('server_version_num')::integer >= 170000 then
      if has_table_privilege(browser_role, 'public.listings', 'MAINTAIN') then
        raise exception 'Unexpected effective MAINTAIN privilege on listings for %.', browser_role;
      end if;
    end if;
    for listing_column in
      select column_name from information_schema.columns
      where table_schema = 'public' and table_name = 'listings'
    loop
      foreach privilege_name in array array['SELECT','INSERT','UPDATE','REFERENCES'] loop
        permitted := case privilege_name
          when 'SELECT' then listing_column = any(readable)
          when 'INSERT' then browser_role = 'authenticated'
            and (listing_column = any(editable) or listing_column in ('user_id','client_request_id'))
          when 'UPDATE' then browser_role = 'authenticated' and listing_column = any(editable)
          else false
        end;
        if has_column_privilege(browser_role, 'public.listings', listing_column, privilege_name)
           is distinct from permitted then
          raise exception 'Unexpected effective % privilege on listings.% for %. Review inherited grants.',
            privilege_name, listing_column, browser_role;
        end if;
      end loop;
    end loop;
  end loop;
  if has_function_privilege('anon', 'public.oneoftwo_listing_for_edit(uuid)', 'EXECUTE')
    or has_function_privilege('anon', 'public.oneoftwo_listing_drafts()', 'EXECUTE') then
    raise exception 'Anonymous access to an owner-only listing function remains enabled.';
  end if;
end
$$;

do $$
declare
  id_sequence regclass := pg_get_serial_sequence('public.listings', 'id')::regclass;
begin
  if id_sequence is not null then
    execute format('grant usage, select on sequence %s to authenticated', id_sequence);
  end if;
end
$$;

-- Restrictive policies are also applied when older permissive policies exist.
drop policy if exists oneoftwo_listings_read on public.listings;
drop policy if exists oneoftwo_listings_read_guard on public.listings;
drop policy if exists oneoftwo_listings_write on public.listings;
drop policy if exists oneoftwo_listings_insert_guard on public.listings;
drop policy if exists oneoftwo_listings_update_guard on public.listings;
drop policy if exists oneoftwo_listings_delete_guard on public.listings;
create policy oneoftwo_listings_read on public.listings
  for select to anon, authenticated using (true);
create policy oneoftwo_listings_read_guard on public.listings as restrictive
  for select to anon, authenticated
  using (publication_status = 'published' or user_id = (select auth.uid()));
create policy oneoftwo_listings_write on public.listings
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy oneoftwo_listings_insert_guard on public.listings as restrictive
  for insert to anon, authenticated
  with check (
    user_id = (select auth.uid()) and (select public.oneoftwo_listing_writes_enabled())
    and (image_url is null or image_path is not null
      or image_url !~ '/storage/v1/(object|render/image)/public/listing-images/')
  );
create policy oneoftwo_listings_update_guard on public.listings as restrictive
  for update to anon, authenticated
  using (user_id = (select auth.uid()) and (select public.oneoftwo_listing_writes_enabled()))
  with check (
    user_id = (select auth.uid()) and (select public.oneoftwo_listing_writes_enabled())
    and (image_url is null or image_path is not null
      or image_url !~ '/storage/v1/(object|render/image)/public/listing-images/')
  );
create policy oneoftwo_listings_delete_guard on public.listings as restrictive
  for delete to anon, authenticated
  using (user_id = (select auth.uid()) and (select public.oneoftwo_listing_writes_enabled()));

-- Other buckets keep their existing access rules. These guards apply even
-- if another permissive policy already exists on storage.objects.
drop policy if exists oneoftwo_listing_images_read on storage.objects;
drop policy if exists oneoftwo_listing_images_read_guard on storage.objects;
drop policy if exists oneoftwo_listing_images_insert on storage.objects;
drop policy if exists oneoftwo_listing_images_insert_guard on storage.objects;
drop policy if exists oneoftwo_listing_images_update_guard on storage.objects;
drop policy if exists oneoftwo_listing_images_delete on storage.objects;
drop policy if exists oneoftwo_listing_images_delete_guard on storage.objects;

create policy oneoftwo_listing_images_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'listing-images');
create policy oneoftwo_listing_images_read_guard on storage.objects as restrictive
  for select to anon, authenticated
  using (
    bucket_id <> 'listing-images'
    or split_part(name, '/', 1) = (select auth.uid())::text
    or exists (
      select 1 from public.listings as l
      where l.image_path = storage.objects.name and l.publication_status = 'published'
    )
  );

create policy oneoftwo_listing_images_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'listing-images');
create policy oneoftwo_listing_images_insert_guard on storage.objects as restrictive
  for insert to anon, authenticated
  with check (
    bucket_id <> 'listing-images'
    or (
      (select public.oneoftwo_listing_writes_enabled())
      and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$')
    )
  );

create policy oneoftwo_listing_images_update_guard on storage.objects as restrictive
  for update to anon, authenticated
  using (bucket_id <> 'listing-images') with check (bucket_id <> 'listing-images');

create policy oneoftwo_listing_images_delete on storage.objects
  for delete to authenticated using (bucket_id = 'listing-images');
create policy oneoftwo_listing_images_delete_guard on storage.objects as restrictive
  for delete to anon, authenticated
  using (
    bucket_id <> 'listing-images'
    or (
      (select public.oneoftwo_listing_writes_enabled())
      and split_part(name, '/', 1) = (select auth.uid())::text
      and not exists (
        select 1 from public.listings as l where l.image_path = storage.objects.name
      )
    )
  );

-- Browser roles cannot change the visibility setting of listing-images.
drop policy if exists oneoftwo_listing_bucket_insert_guard on storage.buckets;
drop policy if exists oneoftwo_listing_bucket_update_guard on storage.buckets;
drop policy if exists oneoftwo_listing_bucket_delete_guard on storage.buckets;
create policy oneoftwo_listing_bucket_insert_guard on storage.buckets as restrictive
  for insert to anon, authenticated with check (id <> 'listing-images');
create policy oneoftwo_listing_bucket_update_guard on storage.buckets as restrictive
  for update to anon, authenticated using (id <> 'listing-images') with check (id <> 'listing-images');
create policy oneoftwo_listing_bucket_delete_guard on storage.buckets as restrictive
  for delete to anon, authenticated using (id <> 'listing-images');

notify pgrst, 'reload schema';
commit;
