async function loadListingDrafts() {
  const section = document.getElementById('drafts');
  const list = document.getElementById('draftsList');
  const status = document.getElementById('draftsStatus');
  section.hidden = false;
  list.replaceChildren();
  status.textContent = 'Loading drafts…';

  try {
    const { data, error } = await OneOfTwoAuth.getClient()
      .rpc('oneoftwo_listing_drafts');
    if (error) throw error;

    status.textContent = data.length ? '' : 'You have no drafts yet.';
    const entries = data.map(draft => {
      const entry = document.createElement('li');
      const link = document.createElement('a');
      link.href = 'add-listing.html?draft=' + encodeURIComponent(draft.client_request_id);
      link.textContent = draft.title;
      entry.append(link);
      return entry;
    });
    list.replaceChildren(...entries);
  } catch (error) {
    console.error('Unable to load drafts:', error);
    status.textContent = 'Could not load your drafts. Refresh the page to try again.';
  }
}
