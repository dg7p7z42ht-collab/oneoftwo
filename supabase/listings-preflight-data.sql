-- Read-only. Run after listings-preflight.sql confirms the baseline table exists.
-- The origin below is the Project URL used by the production OneOfTwo code.
begin read only;
set local statement_timeout = '15s';

with target as (
  select 'https://lnbrqcklgndbizlhkdef.supabase.co/storage/v1/object/public/listing-images/'::text as prefix
), listing_rows as (
  select l.user_id, l.publication_status::text as kind,
    to_jsonb(l)->>'image_url' as old_url, to_jsonb(l)->>'image_path' as converted,
    to_jsonb(l)->>'client_request_id' as request_id,
    prefix
  from public.listings as l cross join target
), parsed as (
  select l.*,
    case when left(old_url, length(prefix)) = prefix
      then substr(old_url, length(prefix) + 1) end as old_path
  from listing_rows as l
), checked as (
  select l.*,
    coalesce(converted, case when old_path ~
      ('^' || user_id::text || '/[0-9a-f-]{36}[.](jpg|png|webp)$') then old_path end) as candidate,
    old_url ~ '/storage/v1/(object|render/image)/public/listing-images/' as bucket_url
  from parsed as l
), counts as (
  select count(*) as listings,
    count(*) filter (where kind = 'published') as published,
    count(*) filter (where kind = 'draft') as drafts,
    count(*) filter (where kind is null or kind not in ('published','draft')) as unexpected_status,
    count(*) filter (where user_id is null or not exists (select 1 from auth.users u where u.id = l.user_id)) as missing_owners,
    count(*) filter (where bucket_url) as legacy_bucket_urls,
    count(*) filter (where bucket_url and old_path is null) as legacy_urls_other_host_or_format,
    count(*) filter (where (bucket_url or converted is not null) and o.name is null) as unresolved_photo_objects,
    count(*) filter (where kind is distinct from 'published' and (bucket_url or converted is not null)
      and exists (select 1 from storage.buckets b where b.id='listing-images' and b.public)) as unpublished_photo_references_in_public_bucket,
    count(request_id) - count(distinct request_id) as duplicate_request_ids
  from checked as l
  left join storage.objects as o on o.bucket_id = 'listing-images' and o.name = l.candidate
)
select to_jsonb(counts) || jsonb_build_object('objects_without_matched_listing', (
  select count(*) from storage.objects as o where o.bucket_id='listing-images'
  and not exists (select 1 from checked as c where c.candidate = o.name)
)) as inventory
from counts;

rollback;
