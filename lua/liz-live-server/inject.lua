-- inject.lua — splice the reload <script> into served HTML and supply the
-- client JS served at /__liz_reload.js.
local M = {}

-- The route paths the client/script use. Kept here so server + inject agree.
M.SSE_PATH = "/__liz_reload"
M.CLIENT_JS_PATH = "/__liz_reload.js"

-- The SSE event payload that means "reload now" — the contract between the
-- server (sse.broadcast) and the injected client below. One source of truth.
M.RELOAD_MSG = "reload"

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
  var es = null;
  var backoff = 1000;
  var BACKOFF_MAX = 10000;
  var hadDisconnect = false;
  var badge = null;

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
      if (e.data === RELOAD_MSG) location.reload();
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
]]):format(M.SSE_PATH, M.RELOAD_MSG)

return M
