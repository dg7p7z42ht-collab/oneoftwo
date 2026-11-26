const OneOfTwoListings = (() => {
  const categories = Object.freeze({
    fashion: "Fashion & Shoes",
    jewellery: "Jewellery & Watches",
    home: "Home & Living",
    automotive: "Automotive",
    sports: "Sports & Outdoors",
    electronics: "Electronics",
    tools: "Tools & Hardware",
    toys: "Toys & Games",
    collectibles: "Collectibles & Sets",
    lost: "Lost & Found",
    parts: "Missing Parts"
  });
  const fields = "id, title, description, listing_type, category, image_path, image_url";

  function categoryName(category) {
    return Object.hasOwn(categories, category) ? categories[category] : null;
  }

  function typeLabel(type) {
    return type === "wanted" ? "Wanted" : "Available";
  }

  function legacyImageUrl(value) {
    if (!value) return null;
    try {
      const url = new URL(value);
      return url.protocol === "https:" ? url.href : null;
    } catch {
      return null;
    }
  }

  async function imageUrls(client, listings) {
    const urls = new Map(listings.map(item => [item.id, legacyImageUrl(item.image_url)]));
    const paths = [...new Set(listings.map(item => item.image_path).filter(Boolean))];
    if (!paths.length) return urls;

    try {
      const { data, error } = await client.storage
        .from("listing-images")
        .createSignedUrls(paths, 3600);
      if (error) throw error;
      const signedUrls = new Map(data.filter(entry => entry.signedUrl)
        .map(entry => [entry.path, entry.signedUrl]));
      for (const item of listings) {
        const signedUrl = signedUrls.get(item.image_path);
        if (signedUrl) urls.set(item.id, signedUrl);
      }
    } catch (error) {
      console.warn("Unable to load some listing photos.", error);
    }

    return urls;
  }

  return { categoryName, fields, imageUrls, typeLabel };
})();
