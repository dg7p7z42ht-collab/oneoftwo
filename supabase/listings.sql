-- Run this in the SQL Editor of OneOfTwo-Staging first.
-- The transaction aborts if a legacy public listing-images link cannot be mapped.
-- Back up and review production separately before a coordinated release.
begin;

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

-- Existing listing IDs are left alone, including bigint/identity IDs.
do $$
begin
  if exists (
    select required.name
    from unnest(array[
      'id', 'user_id', 'title', 'description', 'category', 'listing_type',
      'publication_status', 'created_at'
    ]) as required(name)
    except
    select column_name::text
    from information_schema.columns
    where table_schema = 'public' and table_name = 'listings'
  ) or (select data_type from information_schema.columns
        where table_schema = 'public' and table_name = 'listings' and column_name = 'user_id')
       is distinct from 'uuid' then
    raise exception 'Incompatible listings table. Review the columns from the existing OneOfTwo schema.';
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

-- Translate URLs from the old upload code only when the exact object exists
-- and its path has the original owner's UUID as its only directory.
update public.listings as l
set image_path = o.name
from storage.objects as o
where l.image_path is null
  and o.bucket_id = 'listing-images'
  and o.name = substring(l.image_url from '^https://[^/?#]+/storage/v1/object/public/listing-images/([^?#]+)$')
  and o.name ~ ('^' || l.user_id::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$');

do $$
begin
  if exists (select 1 from storage.buckets where id = 'listing-images' and public)
    and exists (
      select 1 from public.listings as l
      where l.image_url ~ '^https://[^/?#]+/storage/v1/object/public/listing-images/'
        and not exists (
          select 1 from storage.objects as o
          where o.bucket_id = 'listing-images' and o.name = l.image_path
            and o.name = substring(l.image_url from '^https://[^/?#]+/storage/v1/object/public/listing-images/([^?#]+)$')
        )
    ) then
    raise exception 'Existing public listing-images URLs could not all be mapped. Inspect the legacy objects before making the bucket private.';
  end if;
end
$$;

alter table public.listings drop constraint if exists oneoftwo_listings_image_path_owner;
alter table public.listings add constraint oneoftwo_listings_image_path_owner check (
  image_path is null or (
    user_id is not null and image_path ~ ('^' || user_id::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$')
  )
) not valid;
alter table public.listings validate constraint oneoftwo_listings_image_path_owner;

-- Supabase supports SQL for bucket creation. Manage actual objects via Storage API.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-images', 'listing-images', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

alter table public.listings enable row level security;
revoke insert, update, delete, truncate on public.listings from public, anon;
revoke truncate on public.listings from authenticated;
grant select on public.listings to anon, authenticated;
grant insert, update, delete on public.listings to authenticated;

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
  with check (user_id = (select auth.uid()));
create policy oneoftwo_listings_update_guard on public.listings as restrictive
  for update to anon, authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy oneoftwo_listings_delete_guard on public.listings as restrictive
  for delete to anon, authenticated
  using (user_id = (select auth.uid()));

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
    or name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$')
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
      split_part(name, '/', 1) = (select auth.uid())::text
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

commit;
