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
  /* The harness version this page was written for. An older one is offered its update. */
  harness_version: 3,

  /* Offered until the harness answers with the account's own model list. Any other id can be typed in. */
  models: ["@cf/meta/llama-3.3-70b-instruct-fp8-fast"],

  /* Agent Garrett: where its key comes from, and where it is written about. */
  garrett: {
    dashboard: "https://agent.garrettstimpson.ca/dashboard",
    blog: "https://garrettstimpson.ca/topics/agent-garrett/",
    what: "https://garrettstimpson.ca/posts/2026/11/04/what-is-agent-garrett-system-design/",
    how: "https://garrettstimpson.ca/posts/2026/10/16/how-to-use-agent-garrett/",
  },

  /* Every link the chat carries, in the order shown. */
  links: [
    { group: "Agent Garrett", items: [
      { label: "Agent Garrett dashboard", href: "https://agent.garrettstimpson.ca/dashboard" },
      { label: "What is Agent Garrett?", href: "https://garrettstimpson.ca/posts/2026/11/04/what-is-agent-garrett-system-design/" },
      { label: "How to use Agent Garrett", href: "https://garrettstimpson.ca/posts/2026/10/16/how-to-use-agent-garrett/" },
      { label: "Agent Garrett blog", href: "https://garrettstimpson.ca/topics/agent-garrett/" },
    ] },
    { group: "The veil", items: [
      { label: "Download the desktop app", href: "../#get" },
      { label: "Quick start", href: "../demos/" },
      { label: "Source docs", href: "../#documents" },
      { label: "nl-veil on GitHub", href: "https://github.com/gary23w/nl-veil" },
      { label: "Releases", href: "https://github.com/gary23w/nl-veil/releases" },
      { label: "Microsoft Store", href: "https://apps.microsoft.com/detail/9MVQ78SK0CW6" },
    ] },
    { group: "Related", items: [
      { label: "garrettstimpson.ca", href: "https://garrettstimpson.ca/" },
      { label: "neuron-db", href: "https://gary23w.github.io/neuron-db/" },
      { label: "the-veil-12b", href: "https://huggingface.co/gary23w/the-veil-12b" },
      { label: "gary-neuron-emergent", href: "https://huggingface.co/gary23w/gary-neuron-emergent" },
    ] },
  ],
};
