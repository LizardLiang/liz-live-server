-- markdown.lua — serve Markdown files as pretty, live-reloading HTML.
-- The server sends a tiny HTML shell that embeds the raw Markdown source and
-- pulls in our OWN first-party client-side renderer (/__liz_md.js). No vendored
-- library, no CDN, no external binary — it works fully offline. Rendering +
-- generic syntax highlighting happen in the browser; the shell carries the
-- normal live-reload <script> so Markdown pages reload on save like HTML.
local inject = require("liz-live-server.inject")

local M = {}

-- Cached route serving the renderer JS (mirrors inject.CLIENT_JS_PATH so the
-- browser fetches it once instead of inlining it into every Markdown page).
M.CLIENT_JS_PATH = "/__liz_md.js"

--- True if the path is a Markdown file (case-insensitive extension).
---@param path string
---@return boolean
function M.is_markdown(path)
  local ext = path:match("%.([%w]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  return ext == "md" or ext == "markdown"
end

--- HTML-escape (for the <title> only; the body is rendered client-side).
local function esc(s)
  return (s:gsub("[&<>\"]", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
  }))
end

--- Embed the raw Markdown as a JS string literal safely: JSON-encode, then
--- escape every "<" as < so a literal "</script>" (or "<!--") in the file
--- can never break out of the <script> element.
---@param raw string
---@return string js_string_literal
local function embed(raw)
  local json = vim.json.encode(raw)
  return (json:gsub("<", "\\u003C"))
end

--- Build the HTML shell for a Markdown file. Embeds the source, references the
--- renderer route, and injects the live-reload script.
---@param raw string raw Markdown bytes
---@param path string request/file path (used for the <title>)
---@return string html
function M.shell(raw, path)
  local title = path:gsub("[?#].*$", ""):match("([^/\\]+)$") or "markdown"
  return table.concat({
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>" .. esc(title) .. "</title>",
    "</head>",
    "<body>",
    '<article id="__liz_md_root"></article>',
    "<script>window.__LIZ_MD=" .. embed(raw) .. ";</script>",
    ('<script src="%s"></script>'):format(M.CLIENT_JS_PATH),
    inject.script_tag,
    "</body>",
    "</html>",
  }, "\n")
end

-- ── First-party client renderer (GFM subset) + generic highlighter + CSS ─────
-- Kept in a [==[ ... ]==] long string (JS contains "]]" inside char classes like
-- [^\]], which would close a plain [[ ]] string). No Lua interpolation here.
M.client_js = [==[
(function () {
  "use strict";
  var src = typeof window.__LIZ_MD === "string" ? window.__LIZ_MD : "";

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function escAttr(s) {
    return esc(s).replace(/"/g, "&quot;");
  }

  // ---- generic, language-agnostic syntax highlighter ----------------------
  // One tokenizer for ALL fenced code regardless of the ```lang tag: it colors
  // comments, strings, numbers, and a shared keyword set. Not grammar-perfect
  // per language, but clean and consistent.
  var KEYWORDS = ("if else elif for while do switch case default break continue return " +
    "function func fn def lambda class struct enum interface trait impl extends implements " +
    "new delete try catch finally throw throws const let var val mut public private protected " +
    "static final abstract void int long float double bool boolean string char byte short " +
    "true false null nil none undefined this self super import from export package namespace " +
    "using module require include typeof instanceof in of is as and or not async await yield " +
    "with pass then end match where type where when go defer select chan map range print").split(" ");
  var KWSET = {};
  for (var _k = 0; _k < KEYWORDS.length; _k++) KWSET[KEYWORDS[_k]] = true;

  function isWordChar(c) { return /[A-Za-z0-9_$]/.test(c); }

  function highlight(code) {
    var out = "", i = 0, n = code.length;
    function span(cls, txt) { return '<span class="tok-' + cls + '">' + esc(txt) + "</span>"; }
    while (i < n) {
      var c = code.charAt(i), c2 = code.charAt(i + 1);
      // block comment /* ... */
      if (c === "/" && c2 === "*") {
        var j = code.indexOf("*/", i + 2);
        j = j < 0 ? n : j + 2;
        out += span("comment", code.slice(i, j)); i = j; continue;
      }
      // line comment: //  #  --
      if ((c === "/" && c2 === "/") || c === "#" || (c === "-" && c2 === "-")) {
        var j = code.indexOf("\n", i); if (j < 0) j = n;
        out += span("comment", code.slice(i, j)); i = j; continue;
      }
      // strings: "..."  '...'  `...`  (with backslash escapes)
      if (c === '"' || c === "'" || c === "`") {
        var j = i + 1;
        while (j < n) {
          if (code.charAt(j) === "\\") { j += 2; continue; }
          if (code.charAt(j) === c) { j++; break; }
          j++;
        }
        out += span("string", code.slice(i, j)); i = j; continue;
      }
      // numbers
      if ((c >= "0" && c <= "9") || (c === "." && c2 >= "0" && c2 <= "9")) {
        var j = i + 1;
        while (j < n && /[0-9a-fA-FxXoObB._]/.test(code.charAt(j))) j++;
        out += span("number", code.slice(i, j)); i = j; continue;
      }
      // identifiers / keywords
      if (/[A-Za-z_$]/.test(c)) {
        var j = i + 1;
        while (j < n && isWordChar(code.charAt(j))) j++;
        var w = code.slice(i, j);
        out += KWSET[w] ? span("keyword", w) : esc(w);
        i = j; continue;
      }
      out += esc(c); i++;
    }
    return out;
  }

  // ---- inline Markdown ----------------------------------------------------
  function parseInline(text) {
    var out = "", i = 0, n = text.length, m;
    while (i < n) {
      var c = text.charAt(i);
      // inline code `code`
      if (c === "`") {
        var j = text.indexOf("`", i + 1);
        if (j > i) { out += "<code>" + esc(text.slice(i + 1, j)) + "</code>"; i = j + 1; continue; }
      }
      // image ![alt](url)
      if (c === "!" && text.charAt(i + 1) === "[") {
        m = /^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/.exec(text.slice(i));
        if (m) { out += '<img alt="' + escAttr(m[1]) + '" src="' + escAttr(m[2]) + '">'; i += m[0].length; continue; }
      }
      // link [text](url)
      if (c === "[") {
        m = /^\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/.exec(text.slice(i));
        if (m) { out += '<a href="' + escAttr(m[2]) + '">' + parseInline(m[1]) + "</a>"; i += m[0].length; continue; }
      }
      // bold **..** or __..__
      if ((c === "*" && text.charAt(i + 1) === "*") || (c === "_" && text.charAt(i + 1) === "_")) {
        var d = c + c, j = text.indexOf(d, i + 2);
        if (j > i) { out += "<strong>" + parseInline(text.slice(i + 2, j)) + "</strong>"; i = j + 2; continue; }
      }
      // strikethrough ~~..~~
      if (c === "~" && text.charAt(i + 1) === "~") {
        var j = text.indexOf("~~", i + 2);
        if (j > i) { out += "<del>" + parseInline(text.slice(i + 2, j)) + "</del>"; i = j + 2; continue; }
      }
      // italic *..* or _.._
      if (c === "*" || c === "_") {
        var j = text.indexOf(c, i + 1);
        if (j > i + 0) { out += "<em>" + parseInline(text.slice(i + 1, j)) + "</em>"; i = j + 1; continue; }
      }
      out += esc(c); i++;
    }
    return out;
  }

  // ---- block helpers ------------------------------------------------------
  function isBlank(s) { return /^\s*$/.test(s); }
  function isBlockStart(s) {
    return /^\s*(#{1,6}\s|>|```|~~~|([-*+]|\d+[.)])\s)/.test(s) ||
      /^\s*([-*_])(\s*\1){2,}\s*$/.test(s);
  }
  function splitRow(line) {
    var s = line.trim().replace(/^\|/, "").replace(/\|$/, "");
    var cells = [], cur = "";
    for (var k = 0; k < s.length; k++) {
      if (s.charAt(k) === "\\" && s.charAt(k + 1) === "|") { cur += "|"; k++; continue; }
      if (s.charAt(k) === "|") { cells.push(cur.trim()); cur = ""; } else cur += s.charAt(k);
    }
    cells.push(cur.trim());
    return cells;
  }
  function alignAttr(a) { return a ? ' style="text-align:' + a + '"' : ""; }

  function parseList(lines, start) {
    var first = /^(\s*)([-*+]|\d+[.)])\s+/.exec(lines[start]);
    var baseIndent = first[1].length;
    var ordered = /\d/.test(first[2]);
    var items = [], i = start;
    while (i < lines.length) {
      var m = /^(\s*)([-*+]|\d+[.)])\s+([\s\S]*)$/.exec(lines[i]);
      if (!m) break;
      var indent = m[1].length;
      if (indent < baseIndent) break;
      if (indent > baseIndent) {
        var sub = parseList(lines, i);
        if (items.length) items[items.length - 1].children += sub.html;
        i = sub.i;
        continue;
      }
      var content = m[3];
      var task = /^\[([ xX])\]\s+([\s\S]*)$/.exec(content);
      var isTask = false, checked = false;
      if (task) { isTask = true; checked = task[1].toLowerCase() === "x"; content = task[2]; }
      items.push({ text: content, children: "", task: isTask, checked: checked });
      i++;
    }
    var tag = ordered ? "ol" : "ul";
    var listCls = (items.length && items[0].task) ? ' class="liz-tasklist"' : "";
    var out = "<" + tag + listCls + ">";
    for (var k = 0; k < items.length; k++) {
      var it = items[k];
      var inner = it.task
        ? '<input type="checkbox" disabled' + (it.checked ? " checked" : "") + "> " + parseInline(it.text)
        : parseInline(it.text);
      out += "<li" + (it.task ? ' class="liz-task"' : "") + ">" + inner + it.children + "</li>";
    }
    out += "</" + tag + ">";
    return { html: out, i: i };
  }

  // ---- block Markdown -----------------------------------------------------
  function render(md) {
    var lines = md.replace(/\r\n?/g, "\n").split("\n");
    var html = [], i = 0;
    while (i < lines.length) {
      var line = lines[i];

      // fenced code ``` / ~~~
      var fence = /^\s*(```+|~~~+)\s*([^\s`]*)\s*$/.exec(line);
      if (fence) {
        var marker = fence[1].charAt(0), minlen = fence[1].length, lang = fence[2] || "";
        var buf = []; i++;
        while (i < lines.length) {
          var cl = /^\s*(```+|~~~+)\s*$/.exec(lines[i]);
          if (cl && cl[1].charAt(0) === marker && cl[1].length >= minlen) { i++; break; }
          buf.push(lines[i]); i++;
        }
        html.push('<pre class="liz-code"><code' + (lang ? ' data-lang="' + escAttr(lang) + '"' : "") +
          ">" + highlight(buf.join("\n")) + "</code></pre>");
        continue;
      }

      if (isBlank(line)) { i++; continue; }

      // ATX heading
      var h = /^(#{1,6})\s+(.*)$/.exec(line);
      if (h) {
        var lv = h[1].length;
        html.push("<h" + lv + ">" + parseInline(h[2].replace(/\s+#+\s*$/, "")) + "</h" + lv + ">");
        i++; continue;
      }

      // horizontal rule
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { html.push("<hr>"); i++; continue; }

      // blockquote (recursive)
      if (/^\s*>/.test(line)) {
        var buf = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, "")); i++; }
        html.push("<blockquote>" + render(buf.join("\n")) + "</blockquote>");
        continue;
      }

      // GFM table: header row + separator row of ---/:--:
      if (line.indexOf("|") >= 0 && i + 1 < lines.length &&
        /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
        var header = splitRow(line);
        var aligns = splitRow(lines[i + 1]).map(function (c) {
          var l = c.charAt(0) === ":", r = c.charAt(c.length - 1) === ":";
          return (l && r) ? "center" : r ? "right" : l ? "left" : "";
        });
        i += 2;
        var rows = [];
        while (i < lines.length && lines[i].indexOf("|") >= 0 && !isBlank(lines[i])) { rows.push(splitRow(lines[i])); i++; }
        var t = "<table><thead><tr>";
        for (var c = 0; c < header.length; c++) t += "<th" + alignAttr(aligns[c]) + ">" + parseInline(header[c]) + "</th>";
        t += "</tr></thead><tbody>";
        for (var r = 0; r < rows.length; r++) {
          t += "<tr>";
          for (var c = 0; c < rows[r].length; c++) t += "<td" + alignAttr(aligns[c]) + ">" + parseInline(rows[r][c]) + "</td>";
          t += "</tr>";
        }
        t += "</tbody></table>";
        html.push(t);
        continue;
      }

      // list
      if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
        var res = parseList(lines, i);
        html.push(res.html); i = res.i; continue;
      }

      // paragraph
      var buf = [];
      while (i < lines.length && !isBlank(lines[i]) && !isBlockStart(lines[i])) { buf.push(lines[i]); i++; }
      html.push("<p>" + parseInline(buf.join("\n").replace(/\n/g, " ")) + "</p>");
    }
    return html.join("\n");
  }

  // ---- styles -------------------------------------------------------------
  var CSS = [==CSS==];

  function injectCss() {
    var st = document.createElement("style");
    st.textContent = CSS;
    document.head.appendChild(st);
  }

  function boot() {
    var root = document.getElementById("__liz_md_root");
    if (!root) return;
    try { root.innerHTML = render(src); }
    catch (e) { root.innerHTML = "<pre>" + esc(src) + "</pre>"; }
  }

  injectCss();
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
]==]

-- The stylesheet, kept separate for readability and spliced into client_js
-- above. GitHub-ish typography with prefers-color-scheme light/dark and token
-- color CSS variables the highlighter's spans reference.
local CSS = [=[
:root{
  --fg:#1f2328; --bg:#ffffff; --muted:#59636e; --border:#d1d9e0;
  --code-bg:#f6f8fa; --link:#0969da; --quote-bar:#d1d9e0;
  --tok-comment:#59636e; --tok-string:#0a3069; --tok-number:#0550ae; --tok-keyword:#cf222e;
}
@media (prefers-color-scheme: dark){
  :root{
    --fg:#e6edf3; --bg:#0d1117; --muted:#9198a1; --border:#3d444d;
    --code-bg:#151b23; --link:#4493f8; --quote-bar:#3d444d;
    --tok-comment:#9198a1; --tok-string:#a5d6ff; --tok-number:#79c0ff; --tok-keyword:#ff7b72;
  }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
#__liz_md_root{max-width:820px;margin:0 auto;padding:2.5rem 1.25rem 5rem;}
#__liz_md_root>*:first-child{margin-top:0}
h1,h2,h3,h4,h5,h6{margin:1.6em 0 .6em;line-height:1.25;font-weight:600}
h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
h3{font-size:1.25em} h4{font-size:1em} h5{font-size:.875em} h6{font-size:.85em;color:var(--muted)}
p{margin:0 0 1em} a{color:var(--link);text-decoration:none} a:hover{text-decoration:underline}
img{max-width:100%}
ul,ol{margin:0 0 1em;padding-left:2em} li{margin:.2em 0}
ul.liz-tasklist{list-style:none;padding-left:1.2em} li.liz-task input{margin-right:.5em}
blockquote{margin:0 0 1em;padding:0 1em;color:var(--muted);border-left:.25em solid var(--quote-bar)}
hr{height:1px;border:0;background:var(--border);margin:1.5em 0}
code{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;font-size:.9em;
  background:var(--code-bg);padding:.2em .4em;border-radius:6px}
pre.liz-code{background:var(--code-bg);padding:1em;border-radius:8px;overflow:auto;margin:0 0 1em}
pre.liz-code code{background:none;padding:0;font-size:.875em;line-height:1.5;display:block}
table{border-collapse:collapse;margin:0 0 1em;display:block;overflow:auto;width:max-content;max-width:100%}
th,td{border:1px solid var(--border);padding:.4em .8em} th{background:var(--code-bg)}
.tok-comment{color:var(--tok-comment);font-style:italic}
.tok-string{color:var(--tok-string)}
.tok-number{color:var(--tok-number)}
.tok-keyword{color:var(--tok-keyword)}
]=]

-- Splice the stylesheet into the client JS as a JS string literal (JSON-encoded
-- so newlines/quotes are safe, then "<" defused like the embedded source).
M.client_js = M.client_js:gsub("%[==CSS==%]", function()
  return (vim.json.encode(CSS):gsub("<", "\\u003C"))
end)

return M
