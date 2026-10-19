// GET /api/revoked : the licenses that no longer work (refunded or charged back), as one-way
// hashes of their orders. Licensed copies of LunchboxWM check this about once a week; the request
// carries nothing about the Mac or the license. Cached for an hour.
export async function onRequestGet({ request, env }) {
  const cache = typeof caches !== "undefined" ? caches.default : null;
  const hit = cache && (await cache.match(request));
  if (hit) return hit;
  const revoked = [];
  let cursor;
  do {
    const page = env.REVOKED ? await env.REVOKED.list({ prefix: "r:", cursor }) : { keys: [], list_complete: true };
    for (const key of page.keys) revoked.push(key.name.slice(2));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  const response = new Response(JSON.stringify({ revoked }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" },
  });
  if (cache) await cache.put(request, response.clone());
  return response;
}
