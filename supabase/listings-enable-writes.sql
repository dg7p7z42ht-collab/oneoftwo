-- Run only after Phase 2 and a read-only check of published photos.
begin;
do $$
begin
  if not exists (select 1 from storage.buckets where id = 'listing-images' and not public)
    or not exists (select 1 from public.oneoftwo_listing_rollout where singleton and cutover_complete) then
    raise exception 'The private listing bucket or rollout setup is missing.';
  end if;
end
$$;
update public.oneoftwo_listing_rollout set writes_enabled = true where singleton;
commit;
