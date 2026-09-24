// Прогресс по программе: читает issues репозитория через публичный GitHub API.
(function () {
  var REPO = 'PaulJurichM/architect-study-plan';
  var API = 'https://api.github.com/repos/' + REPO + '/issues?state=all&per_page=100';
  var CACHE_KEY = 'study-progress-v1';
  var TTL = 2 * 60 * 1000;

  function cacheGet() {
    try {
      var c = JSON.parse(sessionStorage.getItem(CACHE_KEY) || 'null');
      if (c && Date.now() - c.t < TTL) return c.d;
    } catch (e) {}
    return null;
  }
  function cacheSet(d) {
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), d: d })); } catch (e) {}
  }

  function load() {
    var cached = cacheGet();
    if (cached) return Promise.resolve(cached);
    return fetch(API, { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (r) { if (!r.ok) throw new Error('GitHub API ' + r.status); return r.json(); })
      .then(function (items) {
        var d = items.filter(function (i) { return !i.pull_request; }).map(function (i) {
          return {
            n: i.number, title: i.title, state: i.state, url: i.html_url, body: i.body || '',
            ms: i.milestone ? i.milestone.title : 'Без блока',
            msn: i.milestone ? i.milestone.number : 999
          };
        });
        cacheSet(d);
        return d;
      });
  }

  function checks(body) {
    var all = (body.match(/^\s*[-*] \[[ xX]\]/gm) || []).length;
    var done = (body.match(/^\s*[-*] \[[xX]\]/gm) || []).length;
    return { done: done, all: all };
  }
  function score(i) {
    if (i.state === 'closed') return 1;
    var c = checks(i.body);
    return c.all ? c.done / c.all : 0;
  }
  function status(i) {
    if (i.state === 'closed') return { cls: 'sp-done', text: '✓ Пройден' };
    var c = checks(i.body);
    if (c.done > 0) return { cls: 'sp-wip', text: 'В работе: ' + c.done + ' из ' + c.all };
    return { cls: 'sp-todo', text: 'Не начат' };
  }
  function pageUrl(i) {
    var m = i.body.match(/\*\*Материал:\*\*\s*(\S+)/);
    return m ? m[1] : i.url;
  }
  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }
  function pct(x) { return Math.round(x * 100); }

  // Плашка статуса на странице модуля
  function renderBadge(n) {
    var h1 = document.querySelector('#main-content h1');
    if (!h1) return;
    var box = document.createElement('div');
    box.className = 'sp-badge';
    var link = '<a href="https://github.com/' + REPO + '/issues/' + n + '" target="_blank" rel="noopener">Отметить прогресс в issue #' + n + '</a>';
    box.innerHTML = '<span class="sp-pill sp-todo">…</span>' + link;
    h1.insertAdjacentElement('afterend', box);
    load().then(function (d) {
      var i = d.filter(function (x) { return x.n === n; })[0];
      if (!i) return;
      var s = status(i);
      box.className = 'sp-badge ' + s.cls;
      box.firstChild.textContent = s.text;
      box.firstChild.className = 'sp-pill';
    }).catch(function () { box.firstChild.remove(); });
  }

  // Страница «Прогресс»
  function renderProgress(root) {
    root.innerHTML = '<p class="sp-note">Загружаю данные из GitHub…</p>';
    load().then(function (d) {
      var groups = {};
      d.forEach(function (i) { (groups[i.msn] = groups[i.msn] || { title: i.ms, items: [] }).items.push(i); });
      var keys = Object.keys(groups).sort(function (a, b) { return a - b; });
      var total = 0, closed = 0, sum = 0;
      var html = '';
      keys.forEach(function (k) {
        var g = groups[k];
        g.items.sort(function (a, b) { return a.n - b.n; });
        var gs = 0, gc = 0;
        var rows = g.items.map(function (i) {
          var s = status(i);
          gs += score(i); if (i.state === 'closed') gc++;
          return '<li><span class="sp-pill ' + s.cls + '">' + esc(s.text) + '</span>' +
            '<a class="sp-title" href="' + esc(pageUrl(i)) + '">' + esc(i.title) + '</a>' +
            '<a class="sp-issue" href="' + esc(i.url) + '" target="_blank" rel="noopener">#' + i.n + '</a></li>';
        }).join('');
        total += g.items.length; closed += gc; sum += gs;
        var p = pct(gs / g.items.length);
        html += '<section class="sp-block"><h2>' + esc(g.title) + '</h2>' +
          '<div class="sp-bar"><span style="width:' + p + '%"></span></div>' +
          '<div class="sp-meta">' + p + '% · пройдено модулей: ' + gc + ' из ' + g.items.length + '</div>' +
          '<ul class="sp-list">' + rows + '</ul></section>';
      });
      var tp = total ? pct(sum / total) : 0;
      root.innerHTML = '<div class="sp-total"><strong>Всего: ' + tp + '%</strong> · пройдено модулей: ' + closed + ' из ' + total +
        '<div class="sp-bar"><span style="width:' + tp + '%"></span></div></div>' + html;
    }).catch(function (e) {
      root.innerHTML = '<p class="sp-note">Не удалось получить данные из GitHub (' + esc(e.message) +
        '). Прогресс можно посмотреть на <a href="https://github.com/' + REPO + '/milestones">странице milestones</a>.</p>';
    });
  }

  function init() {
    var meta = document.querySelector('meta[name="study-issue"]');
    if (meta && meta.content) renderBadge(parseInt(meta.content, 10));
    var root = document.getElementById('sp-progress');
    if (root) renderProgress(root);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
