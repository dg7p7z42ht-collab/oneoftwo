document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('listingForm');
  const authStatus = document.getElementById('authStatus');
  const loginLink = document.getElementById('signInLink');
  const status = document.getElementById('listingStatus');
  const result = document.getElementById('listingResult');
  const resultLink = document.getElementById('listingResultLink');
  const preview = document.getElementById('preview');
  const previewButton = document.getElementById('previewListingButton');
  const previewPhoto = document.getElementById('previewPhoto');
  const draftButton = document.getElementById('saveDraftButton');
  const publishButton = document.getElementById('publishListingButton');
  const titleInput = document.getElementById('itemTitle');
  const categoryInput = document.getElementById('itemCategory');
  const descriptionInput = document.getElementById('itemDescription');
  const photoInput = document.getElementById('itemImage');
  const editorFields = [...form.querySelectorAll('input, select, textarea')];
  const extensions = new Map([
    ['image/jpeg', 'jpg'], ['image/png', 'png'], ['image/webp', 'webp']
  ]);
  const maxPhotoSize = 10 * 1024 * 1024;
  const rowFields = 'id,title,description,category,listing_type,publication_status,image_path,image_url';
  const request = new URLSearchParams(location.search).get('draft');

  let requestId = request;
  let editorUserId;
  let loading = Boolean(request);
  let saving = false;
  let writesEnabled = false;
  let published = false;
  let savedRow;
  let localPhotoUrl;
  let photoAttempt;
  const attemptedPhotos = new Set();

  function updateControls() {
    editorFields.forEach(field => { field.disabled = loading || saving || published; });
    previewButton.disabled = loading || saving || published;
    draftButton.disabled = loading || saving || published || !editorUserId || !writesEnabled;
    publishButton.disabled = draftButton.disabled;
  }

  function readForm() {
    if (!form.reportValidity()) return null;
    const title = titleInput.value.trim();
    if (!title) {
      status.textContent = 'Enter an item name.';
      titleInput.focus();
      return null;
    }
    const photo = photoInput.files[0];
    if (photo && (!extensions.has(photo.type) || photo.size === 0 || photo.size > maxPhotoSize)) {
      status.textContent = 'Choose a JPG, PNG or WebP file up to 10 MB.';
      photoInput.focus();
      return null;
    }
    return {
      title,
      category: categoryInput.value,
      description: descriptionInput.value.trim(),
      listing_type: form.querySelector('input[name="type"]:checked').value
    };
  }

  async function showPreview(values) {
    document.getElementById('previewType').textContent = values.listing_type === 'wanted'
      ? "I'M LOOKING FOR" : 'I HAVE';
    document.getElementById('previewTitle').textContent = values.title;
    document.getElementById('previewCategory').textContent = categoryInput.selectedOptions[0].textContent;
    document.getElementById('previewDescription').textContent = values.description;
    if (localPhotoUrl) URL.revokeObjectURL(localPhotoUrl);
    localPhotoUrl = photoInput.files[0] ? URL.createObjectURL(photoInput.files[0]) : null;
    previewPhoto.hidden = !localPhotoUrl;
    if (localPhotoUrl) previewPhoto.src = localPhotoUrl;
    else previewPhoto.removeAttribute('src');
    preview.hidden = false;
    const row = savedRow;
    if (!localPhotoUrl && row) {
      try {
        const url = await loadSavedPhoto(OneOfTwoAuth.getClient(), row);
        if (url && row === savedRow && !preview.hidden && !photoInput.files[0]) {
          previewPhoto.src = url;
          previewPhoto.hidden = false;
        }
      } catch (error) {
        console.warn('Unable to show saved listing photo:', error);
      }
    }
  }

  function findListing(client) {
    return client.from('listings').select(rowFields)
      .eq('client_request_id', requestId).eq('user_id', editorUserId).maybeSingle();
  }

  async function loadSavedPhoto(client, row) {
    if (row.image_path) {
      const { data } = await client.storage.from('listing-images').createSignedUrl(row.image_path, 300);
      return data?.signedUrl;
    }
    if (row.image_url?.startsWith('https://')) return row.image_url;
  }

  function showPublished(row) {
    published = true;
    status.textContent = 'Listing published.';
    resultLink.href = 'listing.html?id=' + encodeURIComponent(row.id);
    resultLink.textContent = 'View published listing';
    result.hidden = false;
    document.getElementById('newListingLink').hidden = false;
  }

  async function initialize() {
    updateControls();
    try {
      const client = OneOfTwoAuth.getClient();
      const { data, error } = await client.auth.getUser();
      const user = data?.user;
      if (!user && (!error || error.name === 'AuthSessionMissingError')) {
        authStatus.textContent = 'Log in to save or publish a listing.';
        loginLink.hidden = false;
        return;
      }
      if (error) throw error;

      editorUserId = user.id;
      authStatus.textContent = 'You are signed in.';
      if (!requestId) requestId = crypto.randomUUID();
      try {
        const readiness = await client.rpc('oneoftwo_listing_writes_enabled');
        if (readiness.error) throw readiness.error;
        writesEnabled = readiness.data === true;
      } catch (error) {
        console.warn('Unable to check listing write availability:', error);
      }
      if (!writesEnabled) {
        status.textContent = 'Saving and publishing are temporarily paused. You can still preview changes.';
      }
      if (!request) return;
      if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(requestId)) {
        throw new Error('Invalid draft link');
      }
      const response = await findListing(client);
      if (response.error) throw response.error;
      if (!response.data) throw new Error('Draft not found');
      savedRow = response.data;
      titleInput.value = savedRow.title;
      categoryInput.value = savedRow.category;
      descriptionInput.value = savedRow.description || '';
      form.querySelectorAll('input[name="type"]').forEach(input => {
        input.checked = input.value === savedRow.listing_type;
      });
      if (savedRow.publication_status === 'published') showPublished(savedRow);
    } catch (error) {
      console.error('Unable to open listing editor:', error);
      editorUserId = null;
      authStatus.textContent = request
        ? 'Could not open this draft. Check your account or return to the dashboard.'
        : 'Could not check sign-in status. Refresh the page to try again.';
      if (request) {
        resultLink.href = 'dashboard.html';
        resultLink.textContent = 'Back to your drafts';
        result.hidden = false;
      }
    } finally {
      loading = false;
      updateControls();
    }
  }

  async function uploadPhoto(client, photo) {
    if (photoAttempt?.file !== photo) {
      photoAttempt = {
        file: photo,
        path: editorUserId + '/' + crypto.randomUUID() + '.' + extensions.get(photo.type),
        uploaded: false
      };
    }
    if (!photoAttempt.uploaded) {
      attemptedPhotos.add(photoAttempt.path);
      const bucket = client.storage.from('listing-images');
      const { error } = await bucket.upload(photoAttempt.path, photo, {
        contentType: photo.type,
        upsert: false
      });
      if (error) {
        const statusCode = String(error.statusCode ?? error.status);
        const duplicate = statusCode === '409' ||
          (statusCode === '400' && /already exists|duplicate/i.test(error.message));
        if (!duplicate) throw error;
        // A previous upload can succeed before its response reaches this browser.
        const existing = await bucket.createSignedUrl(photoAttempt.path, 60);
        if (existing.error) throw error;
      }
      photoAttempt.uploaded = true;
    }
    return photoAttempt.path;
  }

  async function removeUnusedPhotos(client, imagePath, oldPath) {
    const paths = [...new Set([...attemptedPhotos, oldPath])]
      .filter(path => path && path !== imagePath);
    if (!paths.length) return;
    try {
      const { error } = await client.storage.from('listing-images').remove(paths);
      if (error) console.warn('Unable to remove superseded listing photo:', error);
      else paths.forEach(path => attemptedPhotos.delete(path));
    } catch (error) {
      console.warn('Unable to remove superseded listing photo:', error);
    }
  }

  async function save(publicationStatus) {
    if (saving || published || !editorUserId || !writesEnabled) return;
    status.textContent = '';
    const values = readForm();
    if (!values) return;
    const photo = photoInput.files[0];
    saving = true;
    updateControls();
    result.hidden = true;
    status.textContent = 'Saving listing…';
    const client = OneOfTwoAuth.getClient();
    let operation = 'session';

    try {
      const { data, error } = await client.auth.getUser();
      if (error || data?.user?.id !== editorUserId) {
        editorUserId = null;
        loginLink.hidden = false;
        throw error || new Error('Session changed');
      }

      operation = 'read';
      const current = await findListing(client);
      if (current.error) throw current.error;
      const previous = current.data;
      if (previous?.publication_status === 'published') {
        await removeUnusedPhotos(client, previous.image_path);
        showPublished(previous);
        return;
      }

      operation = 'photo';
      const imagePath = photo ? await uploadPhoto(client, photo) : previous?.image_path ?? null;
      operation = 'save';
      const payload = {
        ...values,
        publication_status: publicationStatus,
        image_path: imagePath,
        image_url: photo ? null : previous?.image_url ?? null
      };
      const table = client.from('listings');
      const write = previous
        ? table.update(payload).eq('client_request_id', requestId)
          .eq('user_id', editorUserId).eq('publication_status', 'draft')
        : table.insert({ ...payload, user_id: editorUserId, client_request_id: requestId });
      const response = await write.select(rowFields).maybeSingle();
      if (response.error) throw response.error;
      if (!response.data) {
        const latest = await findListing(client);
        if (latest.error) throw latest.error;
        if (latest.data?.publication_status === 'published') {
          await removeUnusedPhotos(client, latest.data.image_path);
          showPublished(latest.data);
          return;
        }
        throw new Error('Listing changed before save');
      }
      savedRow = response.data;
      await removeUnusedPhotos(client, imagePath, previous?.image_path);

      if (publicationStatus === 'published') {
        showPublished(savedRow);
      } else {
        history.replaceState(null, '', 'add-listing.html?draft=' + encodeURIComponent(requestId));
        status.textContent = 'Draft saved. You can publish it here or find it in your dashboard.';
        resultLink.href = 'dashboard.html';
        resultLink.textContent = 'View your drafts';
        result.hidden = false;
      }
    } catch (error) {
      console.error('Listing operation failed:', operation, error);
      const messages = {
        session: 'Could not verify your session. Log in again before saving.',
        read: 'Could not check the listing. Try again.',
        photo: 'Could not upload the photo. Try again or choose a different file.',
        save: 'Could not confirm the save. Try again before starting another listing.'
      };
      status.textContent = messages[operation];
    } finally {
      saving = false;
      updateControls();
    }
  }

  form.addEventListener('submit', event => {
    event.preventDefault();
    if (loading || saving || published) return;
    status.textContent = '';
    const values = readForm();
    if (values) showPreview(values);
  });
  draftButton.addEventListener('click', () => save('draft'));
  publishButton.addEventListener('click', () => save('published'));
  photoInput.addEventListener('change', () => {
    if (localPhotoUrl) URL.revokeObjectURL(localPhotoUrl);
    localPhotoUrl = null;
    preview.hidden = true;
  });
  previewPhoto.addEventListener('error', () => { previewPhoto.hidden = true; });
  initialize();
});
