// Visitor stats (deploy/nas-stats): Umami on the office NAS, at
// https://stats.getride.my through a Cloudflare Tunnel. Off unless the web
// build filled in <meta name="getride-stats"> (scripts/ci/stats_meta.sh,
// from the STATS_SCRIPT_URL and STATS_WEBSITE_ID repository variables).
//
// - Only the public pages count: the landing page, /install/<platform>, and
//   the QR pages on qr.getride.my (/ref|me|now/<token>, /q/<kind>/<token>).
//   The signed-in app and the admin are never counted.
// - A QR page is counted without its token (/ref/:token), and the referrer
//   is cut to its site, so no link that names someone is sent.
// - Umami sets no cookies and keeps no IP addresses; a browser asking not to
//   be tracked is not counted.
// - Loaded async; when the NAS is off the script simply doesn't load and
//   nothing else on the page notices.
(function (root) {
  'use strict';

  /** The page as it is counted, or null when it isn't counted. */
  function page(host, path) {
    var p = String(path || '/').replace(/\/+$/, '') || '/';
    var m;
    if (p === '/') return '/';
    if ((m = /^\/install\/([A-Za-z0-9-]{1,20})$/.exec(p))) return '/install/' + m[1].toLowerCase();
    if ((m = /^\/(ref|me|now)\/[^/]+$/.exec(p))) return '/' + m[1] + '/:token';
    if ((m = /^\/q\/([a-z]{1,10})\/[^/]+$/.exec(p))) return '/q/' + m[1] + '/:token';
    return null;
  }

  /** "https://stats.getride.my/s.js <website id>", or null. */
  function config(content) {
    var parts = String(content || '').trim().split(/\s+/);
    if (parts.length !== 2) return null;
    if (!/^https:\/\/[A-Za-z0-9.-]+(\/[A-Za-z0-9._\/-]*)?\.js$/.test(parts[0])) return null;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(parts[1])) return null;
    return { src: parts[0], id: parts[1].toLowerCase() };
  }

  /** The referrer's site only ("https://wa.me"), or "". */
  function site(referrer) {
    var m = /^(https?:\/\/[^\/?#]+)/i.exec(String(referrer || ''));
    return m ? m[1].toLowerCase() : '';
  }

  root.getrideStats = { page: page, config: config, site: site };
  if (typeof document === 'undefined') return;

  try {
    var meta = document.querySelector('meta[name="getride-stats"]');
    var cfg = config(meta && meta.getAttribute('content'));
    var counted = page(location.hostname, location.pathname);
    if (!cfg || !counted) return;
    if (navigator.doNotTrack === '1' || root.doNotTrack === '1') return;
    var s = document.createElement('script');
    s.async = true;
    s.src = cfg.src;
    s.setAttribute('data-website-id', cfg.id);
    s.setAttribute('data-auto-track', 'false');
    s.setAttribute('data-do-not-track', 'true');
    s.onload = function () {
      try {
        if (!root.umami) return;
        root.umami.track(function (props) {
          var out = {};
          for (var k in props) out[k] = props[k];
          out.url = counted;
          out.title = 'get.ride';
          out.referrer = site(props.referrer);
          return out;
        });
      } catch (e) { /* stats never stand in the way */ }
    };
    s.onerror = function () { /* NAS off: nothing counted, nothing else affected */ };
    document.head.appendChild(s);
  } catch (e) { /* stats never stand in the way */ }
})(typeof window !== 'undefined' ? window : globalThis);
