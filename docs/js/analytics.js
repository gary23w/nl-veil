/* Site analytics for gary23w.github.io/nl-veil: Google Analytics 4 through the Google tag (Google Tag Manager
   container GTM-KS82FX34, measurement ID G-WX034L2CZL). Only these web pages load it; the desktop app, its server
   and the browser link extension contain no analytics.

   Consent: Google consent mode starts with every storage type denied, so until the visitor presses Accept the tag
   sets no cookies and sends only cookieless pings. Accept grants analytics_storage; ad storage, ad user data and
   ad personalization stay denied always. The choice is kept in localStorage ("nlv.analytics") and can be changed
   from the privacy page (window.nlvAnalytics.reset()).

   The web chat's Cloudflare login comes back to /chat/ with ?code=&state= in the address until the chat page
   swaps it out; the tag is not loaded while any of those parameters are in the address, so a login code never
   reaches Google. */
(function () {
  var GTM = 'GTM-KS82FX34';
  var KEY = 'nlv.analytics';
  var w = window, d = document;

  var stored = null;
  try { stored = localStorage.getItem(KEY); } catch (e) {}
  var save = function (v) { try { localStorage.setItem(KEY, v); } catch (e) {} };

  w.dataLayer = w.dataLayer || [];
  function gtag() { w.dataLayer.push(arguments); }
  gtag('consent', 'default', {
    analytics_storage: stored === 'granted' ? 'granted' : 'denied',
    ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied',
    wait_for_update: 500
  });
  gtag('set', 'ads_data_redaction', true);
  gtag('set', 'url_passthrough', false);

  var secret = /[?&](code|state|error|error_description)=/;
  var loaded = false;
  function load() {
    if (loaded) return;
    if (secret.test(location.search)) { setTimeout(load, 300); return; }
    loaded = true;
    w.dataLayer.push({ 'gtm.start': new Date().getTime(), event: 'gtm.js' });
    var s = d.createElement('script');
    s.async = true;
    s.src = 'https://www.googletagmanager.com/gtm.js?id=' + GTM;
    d.head.appendChild(s);
  }

  function choose(v) {
    save(v);
    gtag('consent', 'update', { analytics_storage: v });
    var b = d.getElementById('nlv-consent');
    if (b) b.remove();
  }

  function banner() {
    if (d.getElementById('nlv-consent')) return;
    var css = d.createElement('style');
    css.textContent =
      '#nlv-consent{position:fixed;left:16px;right:16px;bottom:16px;z-index:2147483000;max-width:560px;margin:0 auto;' +
      'display:flex;flex-wrap:wrap;gap:10px 16px;align-items:center;padding:14px 16px;border-radius:12px;' +
      'font:14px/1.5 system-ui,sans-serif;background:var(--surface-raised,Canvas);color:var(--text,CanvasText);' +
      'border:1px solid var(--border,GrayText);box-shadow:0 12px 32px -12px rgba(0,0,0,.35)}' +
      '#nlv-consent p{margin:0;flex:1 1 260px}' +
      '#nlv-consent a{color:var(--accent,LinkText)}' +
      '#nlv-consent .acts{display:flex;gap:8px}' +
      '#nlv-consent button{font:inherit;cursor:pointer;padding:6px 14px;border-radius:8px;' +
      'border:1px solid var(--border,GrayText);background:transparent;color:inherit}' +
      '#nlv-consent button.yes{background:var(--accent,LinkText);border-color:var(--accent,LinkText);color:#fff}';
    var root = /\/nl-veil\//.test(location.pathname) ? '/nl-veil/' : '/';
    var b = d.createElement('div');
    b.id = 'nlv-consent';
    b.setAttribute('role', 'region');
    b.setAttribute('aria-label', 'Analytics consent');
    b.innerHTML =
      '<p>This site uses Google Analytics cookies to count visits and see how pages are used. ' +
      '<a href="' + root + 'privacy.html#site-analytics">Details</a></p>' +
      '<div class="acts"><button type="button" class="no">Decline</button>' +
      '<button type="button" class="yes">Accept</button></div>';
    b.querySelector('.no').onclick = function () { choose('denied'); };
    b.querySelector('.yes').onclick = function () { choose('granted'); };
    d.head.appendChild(css);
    d.body.appendChild(b);
  }

  w.nlvAnalytics = {
    reset: function () { try { localStorage.removeItem(KEY); } catch (e) {} banner(); }
  };

  load();
  if (stored !== 'granted' && stored !== 'denied') {
    if (d.body) banner(); else d.addEventListener('DOMContentLoaded', banner);
  }
})();
