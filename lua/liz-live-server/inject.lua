-- inject.lua — splice the reload <script> into served HTML and supply the
-- client JS served at /__liz_reload.js.
local M = {}

-- The route paths the client/script use. Kept here so server + inject agree.
M.SSE_PATH = "/__liz_reload"
M.CLIENT_JS_PATH = "/__liz_reload.js"

-- The SSE event payload that means "reload now" — the contract between the
-- server (sse.broadcast) and the injected client below. One source of truth.
M.RELOAD_MSG = "reload"

-- The SSE event payload prefix that means "navigate to this path" — steers an
-- already-open tab to a new page without a full reload. The path follows the
-- prefix directly in the same frame (e.g. "navigate:/B.html").
M.NAV_PREFIX = "navigate:"

-- The SSE event payload prefix that means "reload if this page depends on
-- this path" — the targeted-reload counterpart to the global RELOAD_MSG. The
-- changed root-relative URL path follows the prefix directly in the same
-- frame (e.g. "reload:/style.css"). The client decides relevance by checking
-- its own same-origin dependency set (own page + linked/scripted/imaged
-- assets); the server never parses HTML for this.
M.RELOAD_PREFIX = "reload:"

-- One cached <script> tag (external src so the client JS is cached once, not
-- inlined into every page — tech-spec "Key Design Decisions").
M.script_tag = ('<script src="%s"></script>'):format(M.CLIENT_JS_PATH)

--- Splice the reload <script> immediately before the first </body>
--- (case-insensitive). If no </body> exists, append to the end of the document.
---@param body string original HTML body
---@return string injected
function M.html(body)
  -- find first case-insensitive </body>
  local lower = body:lower()
  local s = lower:find("</body>", 1, true)
  if s then
    return body:sub(1, s - 1) .. M.script_tag .. body:sub(s)
  end
  return body .. M.script_tag
end

-- Reload client JS (FR-012): EventSource + resync-reload-on-reconnect +
-- disconnected badge + exponential backoff (1s -> cap 10s).
M.client_js = ([[
(function () {
  var SSE_PATH = %q;
  var RELOAD_MSG = %q;
  var NAV_PREFIX = %q;
  var RELOAD_PREFIX = %q;
  var es = null;
  var backoff = 1000;
  var BACKOFF_MAX = 10000;
  var hadDisconnect = false;
  var badge = null;

  function dec(p) {
    try { return decodeURIComponent(p); } catch (_) { return p; }
  }

  // Reload only if `changedPath` (a root-relative URL path, e.g. "/style.css")
  // is something this page actually depends on: its own page (with
  // directory-index equivalence) or a same-origin link/script/img asset it
  // loaded. Known limitation (v1): assets pulled only via CSS (@import,
  // background-image: url()) or injected dynamically after load aren't in the
  // DOM query, so edits to those won't targeted-reload this tab.
  function maybeReload(changedPath) {
    var target = dec(changedPath);
    var deps = {};
    deps[dec(location.pathname)] = true;
    if (location.pathname.charAt(location.pathname.length - 1) === '/') {
      deps[dec(location.pathname + 'index.html')] = true;
    }
    try {
      var els = document.querySelectorAll('link[href],script[src],img[src]');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var ref = el.getAttribute('href') || el.getAttribute('src');
        if (!ref) continue;
        try {
          var url = new URL(ref, location.href);
          if (url.origin === location.origin) {
            deps[dec(url.pathname)] = true;
          }
        } catch (_) {}
      }
    } catch (_) {}
    if (deps[target]) location.reload();
  }

  function showBadge() {
    if (badge) return;
    badge = document.createElement('div');
    badge.textContent = '⚡ live-reload disconnected';
    badge.style.cssText = [
      'position:fixed', 'z-index:2147483647', 'right:12px', 'bottom:12px',
      'background:#b00020', 'color:#fff', 'font:600 12px/1.4 system-ui,sans-serif',
      'padding:6px 10px', 'border-radius:6px', 'box-shadow:0 2px 8px rgba(0,0,0,.3)',
      'pointer-events:none'
    ].join(';');
    var attach = function () {
      if (document.body) document.body.appendChild(badge);
    };
    if (document.body) attach();
    else document.addEventListener('DOMContentLoaded', attach);
  }

  function hideBadge() {
    if (badge && badge.parentNode) badge.parentNode.removeChild(badge);
    badge = null;
  }

  function connect() {
    es = new EventSource(SSE_PATH);

    es.onopen = function () {
      backoff = 1000;
      hideBadge();
      // Resync: a save may have happened while we were disconnected.
      if (hadDisconnect) {
        hadDisconnect = false;
        location.reload();
      }
    };

    es.onmessage = function (e) {
      if (e.data === RELOAD_MSG) { location.reload(); return; }
      if (e.data.indexOf(RELOAD_PREFIX) === 0) { maybeReload(e.data.slice(RELOAD_PREFIX.length)); return; }
      if (e.data.indexOf(NAV_PREFIX) === 0) location.href = e.data.slice(NAV_PREFIX.length);
    };

    es.onerror = function () {
      hadDisconnect = true;
      showBadge();
      try { es.close(); } catch (_) {}
      es = null;
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, BACKOFF_MAX);
    };
  }

  connect();
})();
]]):format(M.SSE_PATH, M.RELOAD_MSG, M.NAV_PREFIX, M.RELOAD_PREFIX)

return M
