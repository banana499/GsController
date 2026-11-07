/* GsController Sunshine 引导页 — 离线静态脚本。
   只调用 /api/sunshine/status（GET，需会话，X-Gs-Session 头）。
   所有动态文本一律使用 textContent，不做任何 HTML 字符串拼接；
   无框架、无外部依赖。本页不收集账号/密码/PIN，不提供旧运行时的
   启停/部署/自启控件，也不把文件或端口检测结果表述为配对或串流成功。 */

(function () {
  'use strict';

  var DEMO_TOKEN = 'gs-console-demo';
  var MODE_DEMO = 'demo';
  var STATUS_PATH = '/api/sunshine/status';

  var mode = document.body.getAttribute('data-mode') === MODE_DEMO ? MODE_DEMO : 'live';

  var sessionToken = null;
  var checkInFlight = false;

  var ERROR_TEXT = {
    Unauthorized: '会话无效或已过期，请从启动器或托盘重新打开 Sunshine 引导页',
    Forbidden: '请求被拒绝：请确认从本机地址打开页面',
    BadRequest: '请求内容无效',
    NotFound: '检查接口不存在',
    TooLarge: '内容过大',
    Conflict: '操作冲突'
  };

  /* ---- 小工具 ---- */

  function $(id) { return document.getElementById(id); }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      var keys = Object.keys(attrs);
      for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var value = attrs[key];
        if (value === null || value === undefined) { continue; }
        if (key === 'text') { node.textContent = value; }
        else if (key === 'class') { node.className = value; }
        else { node.setAttribute(key, value); }
      }
    }
    if (children) {
      for (var j = 0; j < children.length; j++) {
        if (children[j]) { node.appendChild(children[j]); }
      }
    }
    return node;
  }

  function clearNode(node) {
    while (node.firstChild) { node.removeChild(node.firstChild); }
  }

  function announce(text) {
    var region = $('live-region');
    if (region) { region.textContent = text; }
  }

  function fmtClock(iso) {
    var t = Date.parse(iso);
    if (isNaN(t)) { return ''; }
    var d = new Date(t);
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  function errorText(err) {
    if (err && err.code && ERROR_TEXT[err.code]) { return ERROR_TEXT[err.code]; }
    if (err && err.code) { return '检查未完成（代码 ' + err.code + '）'; }
    return '检查未完成';
  }

  /* ---- 会话与 API ---- */

  function readSessionToken() {
    if (mode === MODE_DEMO) { return DEMO_TOKEN; }
    var match = /^#session=([A-Za-z0-9._-]{1,200})$/.exec(window.location.hash);
    if (match) {
      try { window.sessionStorage.setItem('gs-console-session', match[1]); } catch (e) { /* 忽略 */ }
      try { window.history.replaceState(null, '', window.location.pathname + window.location.search); } catch (e2) { /* 忽略 */ }
    }
    try { return window.sessionStorage.getItem('gs-console-session'); } catch (e3) { return null; }
  }

  function api(path, options) {
    var opts = options || {};
    var headers = { 'Accept': 'application/json', 'X-Gs-Session': sessionToken || '' };
    var init = { method: opts.method || 'GET', headers: headers, credentials: 'omit' };
    return window.fetch(path, init).then(function (resp) {
      return resp.json().catch(function () { return null; }).then(function (data) {
        if (!resp.ok) {
          var base = (data && data.error) ? data.error : {};
          var err = {
            status: resp.status,
            code: base.code || ('Http' + resp.status),
            message: base.message || ''
          };
          throw err;
        }
        return (data && data.data !== undefined) ? data.data : data;
      });
    }, function () {
      throw { kind: 'network' };
    });
  }

  function showSessionScreen(kind) {
    $('app').hidden = true;
    var screen = $('session-screen');
    screen.hidden = false;
    $('session-text').textContent = kind === 'expired'
      ? '会话已过期或无效。请关闭此页面，从开始菜单的“GsController”快捷方式重新打开，或从任务栏托盘图标的菜单选择“打开控制台”；新页面会自带新的会话标识。如果是源码目录运行，也可以重新运行 Start-GsController-Sunshine.cmd。'
      : '本页缺少会话标识。请从开始菜单的“GsController”快捷方式重新打开，或从任务栏托盘图标的菜单选择“打开控制台”；不要手动拼链接。如果是源码目录运行，也可以重新运行 Start-GsController-Sunshine.cmd。';
    var title = $('session-title');
    title.textContent = kind === 'expired' ? '会话已过期' : '无法打开 Sunshine 引导页';
    title.focus();
  }

  function handleApiError(err) {
    if (err && (err.kind === 'network' || err.status >= 500)) {
      $('offline-banner').hidden = false;
      $('check-status').textContent = '';
      return;
    }
    if (err && err.status === 401) { showSessionScreen('expired'); return; }
    if (err && err.status === 404) {
      $('check-status').textContent = ERROR_TEXT.NotFound + '；上面的引导步骤仍然有效。';
      return;
    }
    $('check-status').textContent = errorText(err);
  }

  /* ---- 状态渲染（只读提示，绝不表述为配对/串流成功） ---- */

  function pill(kind, label) {
    return el('span', { class: 'diag-pill diag-pill--' + kind, text: label });
  }

  function installedView(value) {
    if (value === true) {
      return ['ready', '已检测到', '在官方默认安装位置检测到 Sunshine 程序文件。这只是文件位置提示，不代表版本或发布者已验证，也不代表安装全部完成。'];
    }
    if (value === false) {
      return ['missing', '未检测到', '在官方默认安装位置没有找到 Sunshine 程序文件。如果安装在自定义位置，可能未被检测到；你仍可以打开第 2 步的管理页继续。'];
    }
    return ['unknown', '未知', '暂时无法确定程序文件状态；未知不代表未安装，也不代表已安装。'];
  }

  function portView(value) {
    if (value === true) {
      return ['ready', '有响应', '本机 TCP 47990 端口有监听响应。这只是端口提示，不代表程序身份已验证、账号已创建或配对已完成。'];
    }
    if (value === false) {
      return ['missing', '无响应', '本机 TCP 47990 端口没有响应。Sunshine 可能尚未安装或尚未启动，可以先完成第 1–2 步。'];
    }
    return ['unknown', '未知', '暂时无法检查管理端口；未知不代表未就绪，也不代表已就绪。'];
  }

  function pairingView(value) {
    if (value === 'notChecked') {
      return ['unknown', '未检查', '配对需要在 Sunshine 管理页的 PIN 页面，确认 Moonlight 客户端显示的 PIN；本页面不检查配对，也不会显示为已配对。'];
    }
    return ['unknown', '未知', '服务端返回了无法识别的配对状态；请以 Sunshine 与 Moonlight 中的实际显示为准。'];
  }

  function streamingView(value) {
    if (value === 'notChecked') {
      return ['unknown', '未检查', '串流是否成功以 Moonlight 客户端的实际连接为准；本页面不检查串流，也不会显示为串流就绪。'];
    }
    return ['unknown', '未知', '服务端返回了无法识别的串流状态；请以 Moonlight 客户端的实际显示为准。'];
  }

  function appendPair(list, dtText, view) {
    list.appendChild(el('dt', { text: dtText }));
    var dd = el('dd', {});
    dd.appendChild(pill(view[0], view[1]));
    dd.appendChild(document.createTextNode(view[2]));
    list.appendChild(dd);
  }

  function renderStatus(data) {
    var d = data || {};
    var list = $('status-facts');
    clearNode(list);
    appendPair(list, '程序文件（官方默认位置）', installedView(d.installed));
    appendPair(list, '管理端口（本机 TCP 47990）', portView(d.managementPortOpen));
    appendPair(list, '配对状态', pairingView(d.pairingStatus));
    appendPair(list, '串流状态', streamingView(d.streamingStatus));
    list.appendChild(el('dt', { text: '检查时间' }));
    list.appendChild(el('dd', { text: d.observedAt ? fmtClock(d.observedAt) : '—' }));
    $('check-status').textContent = mode === MODE_DEMO
      ? '检查完成：以上为演示数据，不代表这台电脑的实际状态。'
      : '检查完成：以上均为提示性结果，不代表已配对或串流就绪。';
  }

  function refreshStatus() {
    if (checkInFlight) { return; }
    if (!$('session-screen').hidden) { return; }
    checkInFlight = true;
    $('btn-refresh').disabled = true;
    $('check-status').textContent = '正在检查…';
    api(STATUS_PATH).then(function (data) {
      checkInFlight = false;
      $('btn-refresh').disabled = false;
      $('offline-banner').hidden = true;
      renderStatus(data);
      announce(mode === MODE_DEMO ? '检查完成：当前显示的是演示数据。' : '检查完成。');
    }, function (err) {
      checkInFlight = false;
      $('btn-refresh').disabled = false;
      handleApiError(err);
    });
  }

  /* ---- 模式标识与事件 ---- */

  function initModeBadge() {
    if (mode !== MODE_DEMO) { return; }
    var badge = $('mode-badge');
    badge.textContent = 'Sunshine 模式（演示数据）';
    badge.className = 'badge badge--demo';
    $('demo-banner').hidden = false;
  }

  function wireEvents() {
    $('btn-refresh').addEventListener('click', refreshStatus);
    $('offline-retry').addEventListener('click', refreshStatus);
    $('session-retry').addEventListener('click', function () { window.location.reload(); });
  }

  function boot() {
    sessionToken = readSessionToken();
    initModeBadge();
    wireEvents();
    if (mode === MODE_DEMO || sessionToken) {
      $('app').hidden = false;
      $('session-screen').hidden = true;
      refreshStatus();
    } else {
      showSessionScreen('missing');
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
}());
