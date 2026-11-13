/* The chat's settings. One object, read once by app.js. */
window.VEIL_WEB = {
  /* Log in with Cloudflare: the nl-veil OAuth client (a public identifier), used with PKCE entirely in this
     page. For the token exchange to work from here, the client must list this page's address as a redirect URL
     and this site's origin under its allowed CORS origins. */
  client_id: "80bc327e23e901c0f92273853011e007",
  auth_url: "https://dash.cloudflare.com/oauth2/auth",
  token_url: "https://dash.cloudflare.com/oauth2/token",
  scopes: "ai.read ai.write user-details.read account-settings.read workers-scripts.read workers-scripts.write offline_access",

  /* The worker harness: Cloudflare's own deploy page, pointed at the harness's folder in the public repo. It puts
     the Worker ("veil-web") in the account of whoever is logged in to Cloudflare. */
  deploy_url: "https://deploy.workers.cloudflare.com/?url=https://github.com/gary23w/nl-veil/tree/main/cloud/veil-web",
  script: "veil-web",

  /* Workers AI model ids offered in the picker. Any other id can be typed in. */
  models: ["@cf/meta/llama-3.3-70b-instruct-fp8-fast"],
};
