/* NL-VEIL FILE — the markdown parser.
   Home-built, zero dependencies. Reads the generated source docs
   (headings, tables, lists, fences, blockquotes, emphasis, links)
   and types them onto bond paper. Everything is escaped on the way
   in; no raw HTML passes through. */
(function (root, factory) {
  'use strict';
  if (typeof module !== 'undefined' && module.exports) module.exports = factory();
  else root.NVMarkdown = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /* ---------------- escaping ---------------- */
  function esc(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function escAttr(s) { return esc(s).replace(/'/g, '&#39;'); }
  function safeUrl(u) {
    var t = u.trim();
    var probe = t.replace(/[\x00- ]+/g, '');
    if (/^(javascript|vbscript|data|file):/i.test(probe)) return '#';
    return t;
  }

  function slug(text) {
    return text.toLowerCase()
      .replace(/`+/g, '')
      .replace(/[^\w\sÀ-￿-]/g, '')
      .trim().replace(/\s+/g, '-') || 'section';
  }

  /* ---------------- inline renderer ----------------
     Placeholder pipeline: code spans and links are lifted out first,
     the remainder is escaped, then emphasis runs on the escaped text,
     then the lifted pieces are stitched back in. */
  function inline(text, opts) {
    opts = opts || {};
    var stash = [];
    function keep(html) { stash.push(html); return '\x00' + (stash.length - 1) + '\x00'; }

    var s = text.replace(/\x00/g, '');

    // code spans: `code`, ``code with ` inside``
    s = s.replace(/(`+)([\s\S]*?[^`])\1(?!`)/g, function (_, ticks, code) {
      if (/^ .* $/.test(code) && code.trim()) code = code.slice(1, -1);
      return keep('<code>' + esc(code) + '</code>');
    });

    if (!opts.noLinks) {
      // images: ![alt](src "title")
      s = s.replace(/!\[([^\]]*)\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+"([^"]*)")?\s*\)/g,
        function (_, alt, src, title) {
          src = src.replace(/^<|>$/g, '');
          return keep('<img src="' + escAttr(safeUrl(src)) + '" alt="' + escAttr(alt) + '"' +
            (title ? ' title="' + escAttr(title) + '"' : '') + ' loading="lazy">');
        });
      // links: [label](href "title")
      s = s.replace(/\[([^\]]+)\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+"([^"]*)")?\s*\)/g,
        function (_, label, href, title) {
          href = href.replace(/^<|>$/g, '');
          return keep(renderLink(href, title, inline(label, { noLinks: true })));
        });
      // autolinks: <https://…>
      s = s.replace(/<(https?:\/\/[^\s<>]+)>/g, function (_, url) {
        return keep(renderLink(url, '', esc(url)));
      });
      // bare urls
      s = s.replace(/(^|[\s(])((?:https?:\/\/)[^\s<>()]+[^\s<>().,;:!?'"])/g, function (_, pre, url) {
        return pre + keep(renderLink(url, '', esc(url)));
      });
    }

    s = esc(s);

    // emphasis on the escaped remainder (NUL-fenced placeholders pass through untouched)
    s = s.replace(/\*\*\*([^*]+)\*\*\*/g, '<strong><em>$1</em></strong>');
    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/(^|[^\w*])\*([^*\s][^*]*?)\*(?![\w*])/g, '$1<em>$2</em>');
    s = s.replace(/(^|[\s(])__([^_]+)__(?=$|[\s).,;:!?])/g, '$1<strong>$2</strong>');
    s = s.replace(/(^|[\s(])_([^_\s][^_]*?)_(?=$|[\s).,;:!?])/g, '$1<em>$2</em>');
    s = s.replace(/~~([^~]+)~~/g, '<del>$1</del>');

    // hard breaks: two trailing spaces before a newline
    s = s.replace(/ {2,}\n/g, '<br>\n');

    // restore stash
    s = s.replace(/\x00(\d+)\x00/g, function (_, n) { return stash[+n]; });
    return s;
  }

  function renderLink(href, title, labelHtml) {
    var url = safeUrl(href);
    var attrs = ' href="' + escAttr(url) + '"';
    if (title) attrs += ' title="' + escAttr(title) + '"';
    // relative .md targets stay in the file — the viewer intercepts these
    var m = /^(?!(?:[a-z]+:)?\/\/)([^#?]+?)\.md(#.*)?$/i.exec(href.trim());
    if (m) attrs += ' data-md="' + escAttr(m[1]) + (m[2] ? escAttr(m[2]) : '') + '"';
    else if (/^(?![a-z]+:|\/|#)[^#?]*\/$/i.test(href.trim())) attrs += ' data-mod="' + escAttr(href.trim()) + '"';
    else if (/^[a-z]+:\/\//i.test(url)) attrs += ' target="_blank" rel="noopener"';
    return '<a' + attrs + '>' + labelHtml + '</a>';
  }

  /* ---------------- table row splitting ---------------- */
  function splitRow(line) {
    var s = line.trim().replace(/^\|/, '').replace(/\|$/, '');
    var cells = [], cur = '', inCode = false, i;
    for (i = 0; i < s.length; i++) {
      var ch = s[i];
      if (ch === '\\' && s[i + 1] === '|') { cur += '|'; i++; continue; }
      if (ch === '`') inCode = !inCode;
      if (ch === '|' && !inCode) { cells.push(cur.trim()); cur = ''; continue; }
      cur += ch;
    }
    cells.push(cur.trim());
    return cells;
  }
  function isDelimRow(line) {
    // GFM allows a single dash per column (:-:, -, --:). Require a pipe so a
    // bare "---" after a stray pipe-line stays an <hr>, never a 1-cell table.
    return line.indexOf('|') !== -1 && line.indexOf('-') !== -1 &&
           /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(line);
  }

  /* ---------------- block parser ---------------- */
  function parseBlocks(src, ids) {
    var lines = src.replace(/\r\n?/g, '\n').split('\n');
    var out = [];
    var i = 0, n = lines.length;

    function isBlank(l) { return /^\s*$/.test(l); }

    while (i < n) {
      var line = lines[i];

      if (isBlank(line)) { i++; continue; }

      // fenced code
      var fence = /^(\s*)(```+|~~~+)\s*([^\s`]*)\s*$/.exec(line);
      if (fence) {
        var close = fence[2].slice(0, 3);
        var buf = [];
        i++;
        while (i < n && lines[i].trim().indexOf(close) !== 0) { buf.push(lines[i]); i++; }
        i++; // consume closing fence (or EOF)
        out.push('<pre class="md-code"><code' +
          (fence[3] ? ' class="lang-' + escAttr(fence[3]) + '"' : '') + '>' +
          esc(buf.join('\n')) + '\n</code></pre>');
        continue;
      }

      // ATX heading
      var h = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
      if (h) {
        var lvl = h[1].length;
        var body = inline(h[2]);
        var id = slug(h[2]);
        var un = id, k = 2;
        while (ids[un]) { un = id + '-' + k++; }
        ids[un] = true;
        out.push('<h' + lvl + ' id="' + un + '">' + body + '</h' + lvl + '>');
        i++;
        continue;
      }

      // hr
      if (/^ {0,3}(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { out.push('<hr>'); i++; continue; }

      // blockquote
      if (/^ {0,3}>/.test(line)) {
        var q = [];
        while (i < n && /^ {0,3}>/.test(lines[i])) {
          q.push(lines[i].replace(/^ {0,3}> ?/, ''));
          i++;
        }
        out.push('<blockquote>' + parseBlocks(q.join('\n'), ids) + '</blockquote>');
        continue;
      }

      // table
      if (line.indexOf('|') !== -1 && i + 1 < n && isDelimRow(lines[i + 1])) {
        var head = splitRow(line);
        var aligns = splitRow(lines[i + 1]).map(function (c) {
          var l = c.charAt(0) === ':', r = c.charAt(c.length - 1) === ':';
          return l && r ? 'center' : r ? 'right' : l ? 'left' : '';
        });
        i += 2;
        var rows = [];
        while (i < n && !isBlank(lines[i]) && lines[i].indexOf('|') !== -1) {
          rows.push(splitRow(lines[i]));
          i++;
        }
        var t = '<div class="md-tablewrap"><table class="md-table"><thead><tr>';
        head.forEach(function (c, ci) {
          t += '<th' + (aligns[ci] ? ' style="text-align:' + aligns[ci] + '"' : '') + '>' + inline(c) + '</th>';
        });
        t += '</tr></thead><tbody>';
        rows.forEach(function (r) {
          t += '<tr>';
          for (var ci = 0; ci < head.length; ci++) {
            t += '<td' + (aligns[ci] ? ' style="text-align:' + aligns[ci] + '"' : '') + '>' +
                 inline(r[ci] !== undefined ? r[ci] : '') + '</td>';
          }
          t += '</tr>';
        });
        t += '</tbody></table></div>';
        out.push(t);
        continue;
      }

      // list
      var li = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/.exec(line);
      if (li) {
        out.push(parseList());
        continue;
      }

      // paragraph: gather until blank or a new block opener
      var para = [line];
      i++;
      while (i < n && !isBlank(lines[i]) &&
             !/^ {0,3}(#{1,6}\s|>|(-{3,}|\*{3,}|_{3,})\s*$|(```|~~~))/.test(lines[i]) &&
             !/^(\s*)([-*+]|\d{1,9}[.)])\s+/.test(lines[i]) &&
             !(lines[i].indexOf('|') !== -1 && i + 1 < n && isDelimRow(lines[i + 1]))) {
        para.push(lines[i]);
        i++;
      }
      out.push('<p>' + inline(para.join('\n')) + '</p>');
    }

    return out.join('\n');

    /* list sub-parser: items own their indented continuations, nesting recurses */
    function parseList() {
      var first = /^(\s*)([-*+]|\d{1,9}[.)])\s+/.exec(lines[i]);
      var indent = first[1].length;
      var ordered = /\d/.test(first[2].charAt(0));
      var start = ordered ? parseInt(first[2], 10) : 1;
      var items = [];

      while (i < n) {
        var m = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/.exec(lines[i]);
        if (m && m[1].length === indent && (/\d/.test(m[2].charAt(0)) === ordered)) {
          var itemLines = [m[3]];
          var contIndent = indent + m[2].length + 1;
          i++;
          while (i < n) {
            if (isBlank(lines[i])) {
              // blank inside an item only if a deeper-indented line follows
              if (i + 1 < n && /^\s/.test(lines[i + 1]) &&
                  (lines[i + 1].match(/^\s*/) || [''])[0].length >= contIndent) {
                itemLines.push('');
                i++;
                continue;
              }
              break;
            }
            var lead = (lines[i].match(/^\s*/) || [''])[0].length;
            var isMarker = /^(\s*)([-*+]|\d{1,9}[.)])\s+/.test(lines[i]);
            if (lead > indent || (isMarker && lead > indent)) {
              itemLines.push(lines[i].slice(Math.min(lead, contIndent)));
              i++;
            } else break;
          }
          // nested blocks inside the item?
          var inner = itemLines.join('\n');
          if (/^(\s*)([-*+]|\d{1,9}[.)])\s+/m.test(inner.split('\n').slice(1).join('\n')) ||
              /\n\s*\n/.test(inner) || /^```|^~~~|^>/m.test(inner.split('\n').slice(1).join('\n'))) {
            var sub = parseBlocks(inner, ids);
            // unwrap a lone leading <p> so tight lists stay tight
            sub = sub.replace(/^<p>([\s\S]*?)<\/p>/, '$1');
            items.push('<li>' + sub + '</li>');
          } else {
            items.push('<li>' + inline(inner) + '</li>');
          }
        } else if (m && m[1].length > indent) {
          // deeper marker without a parent line — treat as nested list in last item
          var nested = parseList();
          if (items.length) items[items.length - 1] = items[items.length - 1].replace(/<\/li>$/, nested + '</li>');
          else items.push('<li>' + nested + '</li>');
        } else break;
      }

      var tag = ordered ? 'ol' : 'ul';
      var attr = ordered && start !== 1 ? ' start="' + start + '"' : '';
      return '<' + tag + attr + '>' + items.join('') + '</' + tag + '>';
    }
  }

  /* ---------------- public api ---------------- */
  function render(src) {
    var ids = {};
    return parseBlocks(String(src || ''), ids);
  }
  function firstHeading(src) {
    var m = /^#{1,6}\s+(.+?)\s*#*\s*$/m.exec(String(src || ''));
    return m ? m[1].replace(/[`*_]/g, '').trim() : '';
  }

  return { render: render, firstHeading: firstHeading };
});
