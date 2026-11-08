// Every request: www.lunchboxwm.com goes to lunchboxwm.com, so search engines see one site; and
// the *.pages.dev preview addresses tell them not to index anything.
export async function onRequest({ request, next }) {
  const url = new URL(request.url);
  if (url.hostname === "www.lunchboxwm.com") {
    url.hostname = "lunchboxwm.com";
    return Response.redirect(url.toString(), 301);
  }
  const response = await next();
  if (url.hostname.endsWith(".pages.dev")) {
    const copy = new Response(response.body, response);
    copy.headers.set("X-Robots-Tag", "noindex");
    return copy;
  }
  return response;
}
