-- Phase 2: run only AFTER deploying and checking the signed-image reader.
-- Set asset_origin to the verified Project URL of the database in this SQL Editor.
begin;
set local lock_timeout = '5s';

lock table public.listings in share row exclusive mode;
lock table public.oneoftwo_listing_rollout in share row exclusive mode;

do $$
declare
  asset_origin constant text := 'REPLACE_WITH_VERIFIED_PROJECT_URL';
  public_prefix constant text := asset_origin || '/storage/v1/object/public/listing-images/';
begin
  if asset_origin !~ '^https://[a-z0-9]{20}[.]supabase[.]co$' then
    raise exception 'Set asset_origin to the verified Supabase Project URL without a trailing slash.';
  end if;
  if not exists (select 1 from public.oneoftwo_listing_rollout where singleton)
    or not exists (select 1 from storage.buckets where id = 'listing-images') then
    raise exception 'Run listings.sql first.';
  end if;
  if public.oneoftwo_listing_writes_enabled() then
    raise exception 'Writes are already enabled. Review the current rollout state before rerunning.';
  end if;

  -- Only map a known local origin and a path owned by the listing owner.
  update public.listings as l
  set image_path = o.name
  from storage.objects as o
  where l.image_path is null
    and left(l.image_url, length(public_prefix)) = public_prefix
    and o.bucket_id = 'listing-images'
    and o.name = substr(l.image_url, length(public_prefix) + 1)
    and o.name ~ ('^' || l.user_id::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$');

  if exists (
    select 1 from public.listings as l
    where (l.image_path is not null
      or l.image_url ~ '/storage/v1/(object|render/image)/public/listing-images/')
      and not exists (
        select 1 from storage.objects as o
        where o.bucket_id = 'listing-images' and o.name = l.image_path
      )
  ) then
    raise exception 'Some existing listing photos cannot be resolved. Review the inventory before switching the bucket.';
  end if;
end
$$;

update storage.buckets
set public = false, file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'listing-images';

-- Check older restrictive policies under the actual anonymous database role.
-- An exception rolls back both the backfill and the change of visibility.
select set_config('oneoftwo.expected_published', (
  select count(*)::text from public.listings where publication_status = 'published'
), true), set_config('oneoftwo.expected_photos', (
  select count(distinct image_path)::text from public.listings
  where publication_status = 'published'
), true);
set local request.jwt.claim.sub = '';
set local request.jwt.claims = '{}';
set local role anon;
do $$
begin
  if (select count(*) from public.listings where publication_status = 'published')
       <> current_setting('oneoftwo.expected_published')::bigint
    or (select count(*) from storage.objects as o
        where o.bucket_id = 'listing-images' and exists (
          select 1 from public.listings as l
          where l.publication_status = 'published' and l.image_path = o.name
        )) <> current_setting('oneoftwo.expected_photos')::bigint then
    raise exception 'Anonymous read check failed. Review existing listings and Storage policies.';
  end if;
end
$$;
reset role;

update public.oneoftwo_listing_rollout set cutover_complete = true where singleton;

-- Keep writes paused until fresh anonymous browsers show the signed photos.
commit;
