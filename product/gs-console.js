/* GsController 本地控制台 — 离线静态脚本。
   只调用共享契约中的 /api/state /api/settings /api/actions /api/jobs/<id>
   与 /api/demo/scenario(仅演示模式)。所有动态文本一律使用 textContent/value,
   不做任何 HTML 字符串拼接;无框架、无外部依赖。 */

(function () {
  'use strict';

  var DEMO_TOKEN = 'gs-console-demo';
  var MODE_DEMO = 'demo';

  var mode = document.body.getAttribute('data-mode') === MODE_DEMO ? MODE_DEMO : 'live';

  var sessionToken = null;
  var stateData = null;
  var settingsInfo = null; /* {revision, settings} */
  var dirtyNames = Object.create(null);
  var currentJob = null; /* {id, action, startedAt} */
  var busyFlag = false;
  var saveInFlight = false; /* 保存 POST 期间锁定表单,防止二次提交与丢输入 */
  var pendingBrowseField = null;
  var lastDiagResult = null;
  var currentView = 'overview';
  var pollTimer = null;
  var noticeTimer = null;
  var backgroundNoteShown = false;

  var ACTIONS = {
    'start': { label: '启动串流', confirm: false },
    'stop': {
      label: '停止', confirm: true, title: '确认停止',
      text: '停止会结束当前的游戏串流运行时。如果客户端正在串流，连接会中断。确定要停止吗？'
    },
    'recover': {
      label: '恢复卡住的会话', confirm: true, title: '确认恢复',
      text: '此操作会停止并重新启动 GameStream 运行时，以清除卡住的会话。如果客户端正在串流，此操作会中断它。确定要继续吗？'
    },
    'check': { label: '检查运行条件', confirm: false },
    'deploy': {
      label: '部署安装', confirm: true, title: '确认部署安装',
      text: '将按已保存的配置写入组件，并可能更新已有产品文件。不会自动启动串流或开启开机自启。请先核对目标目录。',
      details: 'deploy'
    },
    'diagnose': { label: '运行诊断检查', confirm: false },
    'autostart-enable': {
      label: '开启开机自启', confirm: true, title: '确认开启开机自启',
      text: '开启后，开机时会自动启动 GsController 运行时（需要管理员权限）。确定要开启吗？'
    },
    'autostart-disable': {
      label: '关闭开机自启', confirm: true, title: '确认关闭开机自启',
      text: '关闭后，开机时不再自动启动 GsController 运行时。确定要关闭吗？'
    },
    'browse': { label: '选择文件夹', confirm: false, internal: true }
  };

  var STATE_LABELS = {
    needsSetup: '待首次设置',
    stopped: '已停止',
    starting: '正在启动',
    stopping: '正在停止',
    ready: '就绪',
    streaming: '串流中',
    error: '错误',
    unknown: '状态未知'
  };

  var STATE_HINTS = {
    needsSetup: '还没有部署信息，先完成“首次设置”。',
    stopped: '启动后即可在 Moonlight 客户端连接。',
    starting: '正在启动运行时，请稍等。',
    stopping: '正在停止运行时，请稍等。',
    ready: '可以在 Moonlight 客户端连接这台电脑。',
    streaming: '客户端正在串流。',
    error: '运行时报告了错误，请看下面的提示。',
    unknown: '暂时读不到状态，稍后自动刷新。'
  };

  var CHECK_LABELS = {
    runtime: '运行时',
    components: '组件',
    deployment: '部署',
    permissions: '权限',
    status: '运行状态',
    serverinfo: '本机串流接口',
    paths: '目录设置',
    autostart: '开机自启'
  };

  /* 检查项的中文一句话提示;message 原文是英文,只在“详情”里展开 */
  var STATUS_HINTS_CN = {
    ready: '此项已就绪。',
    passed: '此项通过。',
    missing: '此项缺失或未就绪。',
    failed: '此项未通过。',
    warning: '此项需要注意。',
    unknown: '此项结果未知，请勿视为通过。'
  };

  var STATUS_LABELS = {
    ready: '已就绪',
    missing: '缺失',
    warning: '警告',
    unknown: '未知',
    passed: '通过',
    failed: '失败',
    info: '说明'
  };

  var AUTOSTART_LABELS = {
    enabled: '已开启',
    disabled: '已关闭',
    unknown: '未知'
  };

  var ERROR_TEXT = {
    Unauthorized: '会话无效或已过期，请从启动器或托盘重新打开控制台',
    Forbidden: '请求被拒绝：请确认从本机地址打开控制台',
    BadRequest: '请求内容无效',
    Busy: '有操作正在进行，请等它结束',
    LaunchFailed: '启动失败：该动作已记录为失败，请稍后重试',
    RuntimeActive: '请先停止串流，再修改目录或执行部署；显示名称和刷新间隔仍可修改',
    RevisionConflict: '设置已在其他窗口被更新',
    TooLarge: '内容过大',
    NotFound: '接口不存在',
    Conflict: '操作冲突'
  };

  var FIELD_TEXT = {
    EmptyPath: '请选择一个文件夹。',
    TooLong: '目录路径过长，请选择较短的路径。',
    NotAbsolutePath: '请输入本机完整目录，例如 C:\\GsController。',
    InvalidPathSyntax: '目录格式不正确，请重新选择文件夹。',
    DriveRoot: '不能直接使用磁盘根目录，请选择独立文件夹。',
    SystemPath: '不能将 Windows 或系统目录作为目标。',
    NotLocalDrive: '请选择本机固定磁盘上的目录，不支持网络盘。',
    ReparsePath: '请选择实际目录，不要使用目录链接或重解析路径。',
    SameDirectory: '这些目录不能相同，请分别选择。',
    NestedDirectory: '这些目录不能互相包含，请选择独立目录。',
    OverlappingPath: '来源与目标目录不能重叠。',
    TargetNotAllowed: '该目录已有其他内容，请选择新的目录或已有产品目录。',
    InvalidType: '请输入有效的值。',
    InvalidValue: '这个值超出允许范围。',
    required: '必填。',
    tooLong: '长度超出限制。',
    invalidType: '类型无效。',
    outOfRange: '超出允许范围。',
    invalidPath: '需要本机绝对路径（如 C:\\Dir），不支持网络路径。',
    overlappingPaths: '此目录与其他目标目录重复或冲突。',
    unsupportedPath: '不支持此路径（盘符根目录、系统目录或 Windows 目录）。',
    unknownField: '不支持的字段。'
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

  function fmtElapsed(iso) {
    var start = Date.parse(iso);
    if (isNaN(start)) { return '…'; }
    var sec = Math.max(0, Math.floor((Date.now() - start) / 1000));
    var h = Math.floor(sec / 3600);
    var m = Math.floor((sec % 3600) / 60);
    var s = sec % 60;
    function p(n) { return (n < 10 ? '0' : '') + n; }
    if (h > 0) { return h + ':' + p(m) + ':' + p(s); }
    return p(m) + ':' + p(s);
  }

  function errorText(err) {
    if (err && err.code && ERROR_TEXT[err.code]) { return ERROR_TEXT[err.code]; }
    if (err && err.code) { return '操作未完成（代码 ' + err.code + '）'; }
    return '操作未完成';
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
    if (opts.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(opts.body);
    }
    return window.fetch(path, init).then(function (resp) {
      return resp.json().catch(function () { return null; }).then(function (data) {
        if (!resp.ok) {
          var base = (data && data.error) ? data.error : {};
          var err = {
            status: resp.status,
            code: base.code || ('Http' + resp.status),
            message: base.message || '',
            fields: base.fields || []
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
      ? '会话已过期或无效。请在 GsController 目录重新运行 Start-GsController.cmd，或从任务栏托盘图标的菜单选择“打开控制台”；新页面会自带新的会话标识。'
      : '本页缺少会话标识。请在 GsController 目录运行 Start-GsController.cmd，或从任务栏托盘图标的菜单选择“打开控制台”；不要手动拼链接。';
    var title = $('session-title');
    title.textContent = kind === 'expired' ? '会话已过期' : '无法打开本地控制台';
    title.focus();
  }

  function handleApiError(err) {
    if (err && (err.kind === 'network' || err.status >= 500)) {
      $('offline-banner').hidden = false;
      refreshActionButtons();
      return;
    }
    if (err && err.status === 401) { showSessionScreen('expired'); return; }
    announce('刷新失败：' + errorText(err));
  }

  /* ---- 状态轮询 ---- */

  function schedulePoll() {
    if (pollTimer) { window.clearTimeout(pollTimer); }
    if (!$('session-screen').hidden) { pollTimer = null; return; }
    var sec = 2;
    if (settingsInfo && settingsInfo.settings && settingsInfo.settings.pollIntervalSec) {
      sec = Number(settingsInfo.settings.pollIntervalSec);
    }
    if (!(sec >= 1 && sec <= 10)) { sec = 2; }
    pollTimer = window.setTimeout(pollState, sec * 1000);
  }

  function refreshNow() {
    if (pollTimer) { window.clearTimeout(pollTimer); pollTimer = null; }
    pollState();
  }

  function pollState() {
    if (!$('session-screen').hidden) { return; }
    if (document.hidden) { schedulePoll(); return; }
    api('/api/state').then(function (data) {
      stateData = data;
      $('offline-banner').hidden = true;
      renderState();
      schedulePoll();
    }, function (err) {
      handleApiError(err);
      schedulePoll();
    });
  }

  /* ---- 忙态与耗时 ---- */

  function remoteBusy() {
    return !!(stateData && stateData.operation && stateData.operation.status === 'running');
  }

  function setBusyUI(busy) {
    busyFlag = busy;
    refreshActionButtons();
  }

  /* 按钮启用态始终由 capabilities + busyFlag 重算,绝不无条件全启用 */
  function layoutChangesLocked() {
    return !stateData || (stateData.state !== 'stopped' && stateData.state !== 'needsSetup');
  }

  function controlsLocked() {
    return busyFlag || saveInFlight || !stateData || !settingsInfo ||
      !$('offline-banner').hidden || !$('session-screen').hidden;
  }

  function refreshActionButtons() {
    var cap = (stateData && stateData.capabilities) || {};
    var locked = controlsLocked();
    var start = $('btn-start');
    var stop = $('btn-stop');
    start.disabled = locked || !cap.start;
    stop.disabled = locked || !cap.stop;
    start.title = cap.start ? '' : '当前状态不支持启动';
    stop.title = cap.stop ? '' : '当前状态不支持停止';
    var diagBtn = $('btn-diagnose');
    diagBtn.disabled = locked || !cap.diagnose;
    diagBtn.title = cap.diagnose ? '' : '当前不支持诊断';
    var browseOk = !!cap.browse;
    $('btn-browse-component').disabled = locked || !browseOk;
    $('btn-browse-helper').disabled = locked || !browseOk;
    var noEdits = dirtyCount() === 0;
    $('btn-save').disabled = locked || noEdits;
    $('btn-revert').disabled = busyFlag || saveInFlight;
    $('scenario-apply').disabled = locked;
    var capAnyMore = !!(cap.check || cap.deploy || cap.recover || cap.autostart);
    var more = $('btn-more');
    more.disabled = locked || !capAnyMore;
    var moreButtons = document.querySelectorAll('#more-actions button');
    for (var j = 0; j < moreButtons.length; j++) {
      moreButtons[j].disabled = locked || (moreButtons[j].getAttribute('data-action') === 'deploy' && layoutChangesLocked());
    }
    setFormInputsDisabled(saveInFlight);
  }

  function operationLabel() {
    var op = stateData && stateData.operation;
    var action = currentJob ? currentJob.action : (op ? op.action : null);
    var meta = action && ACTIONS[action];
    return meta ? meta.label : (action || '操作');
  }

  function updateElapsed() {
    var op = stateData && stateData.operation;
    var running = !!(currentJob || (op && op.status === 'running'));
    var node = $('hero-elapsed');
    if (!running) { node.hidden = true; return; }
    var startIso = (op && op.status === 'running' && op.startedAt) || (currentJob && currentJob.startedAt);
    if (!startIso) { node.hidden = true; return; }
    node.hidden = false;
    node.textContent = operationLabel() + ' · 已进行 ' + fmtElapsed(startIso);
  }

  /* ---- 总览渲染 ---- */

  function renderState() {
    var s = stateData;
    if (!s) { return; }
    var state = s.state || 'unknown';
    $('hero').setAttribute('data-state', state);
    $('hero-state').textContent = STATE_LABELS[state] || STATE_LABELS.unknown;
    $('hero-message').textContent = STATE_HINTS[state] || s.message || '';
    $('nav-setup').textContent = state === 'needsSetup' ? '首次设置' : '设置';
    $('setup-title').textContent = state === 'needsSetup' ? '首次设置' : '设置';
    renderFacts(s);
    renderNextSteps(s);
    renderPrereq(s);
    renderButtons(s);
    renderAddresses(s);
    maybeSyncSettings(s);
    var busy = !!(currentJob || remoteBusy());
    if (busy !== busyFlag) { setBusyUI(busy); }
  }

  function factRow(dt, ddText) {
    return [el('dt', { text: dt }), el('dd', { text: ddText })];
  }

  function renderFacts(s) {
    var list = $('facts-list');
    clearNode(list);
    var lastOp = '—';
    if (s.lastResult) {
      var meta = ACTIONS[s.lastResult.action];
      var name = meta ? meta.label : s.lastResult.action;
      var verdict = s.lastResult.success === true ? '已完成' : (s.lastResult.success === false ? '未完成' : '已结束');
      lastOp = name + verdict + (s.lastResult.code ? '（' + s.lastResult.code + '）' : '');
      if (s.lastResult.finishedAt) { lastOp += '，' + fmtClock(s.lastResult.finishedAt); }
    }
    var rows = [].concat(
      factRow('显示名称', s.displayName || '—'),
      factRow('状态', STATE_LABELS[s.state || 'unknown'] || '—'),
      factRow('模式', mode === MODE_DEMO ? '演示模式（示例数据）' : '本机'),
      factRow('版本', s.version || '—'),
      factRow('局域网地址', (s.addresses && s.addresses.length) ? s.addresses.join('，') : '—'),
      factRow('管理员权限', s.isElevated ? '是' : '否'),
      factRow('开机自启', AUTOSTART_LABELS[s.autostart] || '未知'),
      factRow('上次操作', lastOp),
      factRow('信息时间', s.updatedAt ? fmtClock(s.updatedAt) : '—')
    );
    /* [].concat 会把每个 [dt,dd] 摊平成节点列表,直接逐节点追加 */
    for (var i = 0; i < rows.length; i++) { list.appendChild(rows[i]); }
  }

  function stepItem(text, button) {
    var li = el('li', { text: text });
    if (button) {
      li.appendChild(document.createTextNode(' '));
      li.appendChild(el('button', {
        type: 'button', class: 'btn btn--quiet step-link', text: button.label
      }));
      li.lastChild.addEventListener('click', button.onClick);
    }
    return li;
  }

  function renderNextSteps(s) {
    var ul = $('next-steps');
    clearNode(ul);
    var items = [];
    switch (s.state) {
      case 'needsSetup':
        items.push(stepItem('打开“首次设置”，确认目录和显示名称。', {
          label: '去设置', onClick: function () { switchView('setup'); }
        }));
        items.push(stepItem('设置完成后，在“更多操作”里执行“部署安装”。'));
        break;
      case 'stopped':
        items.push(stepItem('点击“启动串流”开始运行。'));
        items.push(stepItem('启动成功后，按连接指南添加这台电脑。', {
          label: '查看连接指南', onClick: function () { switchView('guide'); }
        }));
        break;
      case 'starting':
        items.push(stepItem('启动一般几十秒内完成，等待状态刷新即可。'));
        break;
      case 'stopping':
        items.push(stepItem('等待停止完成；长时间停止会由服务端判定结果。'));
        break;
      case 'ready':
        items.push(stepItem('在 Moonlight 客户端里添加并连接这台电脑。', {
          label: '查看连接指南', onClick: function () { switchView('guide'); }
        }));
        break;
      case 'streaming':
        items.push(stepItem('客户端正在串流；如需停止，请先在客户端断开连接。'));
        break;
      case 'error':
        items.push(stepItem('先看上方提示与“部署前检查”；可运行“检查运行条件”定位问题。'));
        items.push(stepItem('会话卡住时可用“恢复卡住的会话”（会中断串流）。'));
        break;
      default:
        items.push(stepItem('稍等片刻自动刷新；持续未知时可运行“检查运行条件”。'));
    }
    for (var i = 0; i < items.length; i++) { ul.appendChild(items[i]); }
  }

  function statusPill(status) {
    var map = {
      ready: 'ready', passed: 'ready', ok: 'ready',
      missing: 'missing', failed: 'missing', error: 'missing',
      warning: 'warning',
      unknown: 'unknown', info: 'unknown'
    };
    var kind = map[status] || 'unknown';
    var label = STATUS_LABELS[status] || (status || '未知');
    return el('span', { class: 'diag-pill diag-pill--' + kind, text: label });
  }

  function checkTitle(item) {
    if (item.id && CHECK_LABELS[item.id]) { return CHECK_LABELS[item.id]; }
    return item.id || '检查项';
  }

  function appendCheckDetails(li, item) {
    var lines = [];
    if (item.id) { lines.push('id: ' + item.id); }
    if (item.label && item.label !== CHECK_LABELS[item.id]) { lines.push('label: ' + item.label); }
    if (item.status) { lines.push('status: ' + item.status); }
    if (item.code) { lines.push('code: ' + item.code); }
    if (item.message) { lines.push('message: ' + item.message); }
    if (!lines.length) { return; }
    var det = el('details', { class: 'check-detail' });
    det.appendChild(el('summary', { text: '详情' }));
    det.appendChild(el('pre', { class: 'check-raw', text: lines.join('\n') }));
    li.appendChild(det);
  }

  function renderCheckItems(listNode, checks) {
    clearNode(listNode);
    if (!checks || !checks.length) {
      listNode.appendChild(el('li', { text: '摘要里没有可显示的检查项。' }));
      return;
    }
    for (var i = 0; i < checks.length; i++) {
      var c = checks[i];
      var li = el('li', {});
      li.appendChild(statusPill(c.status));
      li.appendChild(el('strong', { text: checkTitle(c) + '：' }));
      li.appendChild(document.createTextNode(STATUS_HINTS_CN[c.status] || '结果未知，请勿视为通过。'));
      appendCheckDetails(li, c);
      listNode.appendChild(li);
    }
  }

  function renderPrereq(s) {
    var list = s.prerequisites || [];
    var panel = $('prereq-panel');
    if (!list.length) { panel.hidden = true; return; }
    var allReady = true;
    for (var i = 0; i < list.length; i++) {
      if (list[i].status !== 'ready') { allReady = false; break; }
    }
    var state = s.state || 'unknown';
    /* 全部就绪且不是需要引导/报错的状态时收起;用户主动检查的结果单独展示 */
    var show = !allReady || state === 'needsSetup' || state === 'error';
    panel.hidden = !show;
    if (!show) { return; }
    renderCheckItems($('prereq-list'), list);
  }

  function renderButtons(s) {
    var cap = s.capabilities || {};
    refreshActionButtons();
    var more = $('btn-more');
    var panel = $('more-actions');
    var anyMore = !!(cap.check || cap.deploy || cap.recover || cap.autostart);
    more.hidden = !anyMore;
    if (!anyMore) {
      panel.hidden = true;
      more.setAttribute('aria-expanded', 'false');
      return;
    }
    if (!panel.hidden) { renderMoreActions(s, cap); }
  }

  function moreActionsKey(cap, s) {
    var parts = [];
    if (cap.check) { parts.push('check'); }
    if (cap.deploy) { parts.push('deploy'); }
    if (cap.recover) { parts.push('recover'); }
    if (cap.autostart) { parts.push(s.autostart !== 'enabled' ? 'autostart-enable' : 'autostart-disable'); }
    return parts.join(',');
  }

  var lastMoreKey = null;

  function renderMoreActions(s, cap, force) {
    var panel = $('more-actions');
    var key = moreActionsKey(cap, s || {});
    var active = document.activeElement;
    var focusAction = (active && active.getAttribute && panel.contains(active))
      ? active.getAttribute('data-action') : null;
    /* 菜单项集合未变化时不重建,避免状态轮询把键盘焦点移走 */
    if (!force && key === lastMoreKey) { return; }
    clearNode(panel);
    var busy = controlsLocked();
    if (cap.check) {
      panel.appendChild(el('button', { type: 'button', class: 'btn', text: '检查运行条件', disabled: busy || null }));
    }
    if (cap.deploy) {
      panel.appendChild(el('button', { type: 'button', class: 'btn', text: '部署安装', disabled: busy || layoutChangesLocked() || null }));
    }
    if (cap.recover) {
      panel.appendChild(el('button', { type: 'button', class: 'btn', text: '恢复卡住的会话', disabled: busy || null }));
    }
    if (cap.autostart) {
      var enable = s.autostart !== 'enabled';
      panel.appendChild(el('button', {
        type: 'button', class: 'btn',
        text: enable ? '开启开机自启' : '关闭开机自启',
        disabled: busy || null
      }));
    }
    var buttons = panel.querySelectorAll('button');
    var actions = [];
    if (cap.check) { actions.push('check'); }
    if (cap.deploy) { actions.push('deploy'); }
    if (cap.recover) { actions.push('recover'); }
    if (cap.autostart) { actions.push(s.autostart !== 'enabled' ? 'autostart-enable' : 'autostart-disable'); }
    var onClick = function (event) {
      handleActionClick(event.currentTarget.getAttribute('data-action'));
    };
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute('data-action', actions[i]);
      buttons[i].addEventListener('click', onClick);
    }
    lastMoreKey = key;
    if (focusAction) {
      for (var k = 0; k < buttons.length; k++) {
        if (buttons[k].getAttribute('data-action') === focusAction) {
          buttons[k].focus();
          break;
        }
      }
    }
  }

  /* ---- 动作与任务 ---- */

  function showActionNotice(text) {
    var node = $('action-notice');
    node.textContent = text;
    if (noticeTimer) { window.clearTimeout(noticeTimer); }
    node.hidden = !text;
    noticeTimer = window.setTimeout(function () { node.textContent = ''; node.hidden = true; }, 12000);
  }

  function buildDeployDetails(savedSettings) {
    var box = el('div', {});
    box.appendChild(el('p', { text: '将要使用的目标目录（已保存的配置）：' }));
    var dl = el('dl', { class: 'facts' });
    var settings = savedSettings || {};
    var rows = [
      ['安装目录', settings.installDir],
      ['状态目录', settings.stateDir],
      ['日志目录', settings.logDir]
    ];
    for (var i = 0; i < rows.length; i++) {
      var value = rows[i][1] || '（未填写）';
      dl.appendChild(el('dt', { text: rows[i][0] }));
      dl.appendChild(el('dd', { text: value }));
    }
    box.appendChild(dl);
    return box;
  }

  function confirmDialog(opts) {
    return new Promise(function (resolve) {
      var dlg = $('confirm-dialog');
      var sourceFocus = document.activeElement;
      $('confirm-title').textContent = opts.title || '确认操作';
      $('confirm-text').textContent = opts.text || '';
      var details = $('confirm-details');
      clearNode(details);
      if (opts.details) {
        details.appendChild(opts.details);
        details.hidden = false;
      } else {
        details.hidden = true;
      }
      $('confirm-ok').textContent = opts.confirmLabel || '确认';
      $('confirm-ok').className = opts.danger ? 'btn btn--danger' : 'btn btn--primary';
      dlg.returnValue = '';
      var onClose = function () {
        dlg.removeEventListener('close', onClose);
        var morePanel = $('more-actions');
        var returnToMore = sourceFocus && morePanel.contains(sourceFocus);
        morePanel.hidden = true;
        $('btn-more').setAttribute('aria-expanded', 'false');
        if (returnToMore) { $('btn-more').focus(); }
        resolve(dlg.returnValue === 'confirm');
      };
      dlg.addEventListener('close', onClose);
      dlg.showModal();
      $('confirm-cancel').focus();
    });
  }

  function handleActionClick(action) {
    var meta = ACTIONS[action];
    if (!meta || controlsLocked()) { return; }
    if (action === 'deploy' && layoutChangesLocked()) { showActionNotice(ERROR_TEXT.RuntimeActive); return; }
    if (!meta.confirm) { runAction(action); return; }
    var confirmedRevision = settingsInfo.revision;
    var confirmationText = mode === MODE_DEMO ? '演示模式：此操作只改变演示状态，不会执行真实部署、启停或系统任务。' : meta.text;
    var opts = { title: meta.title, text: confirmationText, confirmLabel: meta.label, danger: action === 'stop' };
    if (meta.details === 'deploy') { opts.details = buildDeployDetails(settingsInfo.settings); }
    confirmDialog(opts).then(function (ok) {
      if (ok) { runAction(action, { confirm: true, revision: confirmedRevision }); }
    });
  }

  function runAction(action, extra) {
    if (controlsLocked()) { return; }
    if (action === 'deploy' && layoutChangesLocked()) { showActionNotice(ERROR_TEXT.RuntimeActive); return; }
    var meta = ACTIONS[action] || { label: action };
    setBusyUI(true);
    var body = {
      action: action,
      revision: (settingsInfo && settingsInfo.revision) ? settingsInfo.revision : 1
    };
    if (extra) {
      for (var key in extra) {
        if (Object.prototype.hasOwnProperty.call(extra, key)) { body[key] = extra[key]; }
      }
    }
    api('/api/actions', { method: 'POST', body: body }).then(function (data) {
      currentJob = { id: data && data.id ? data.id : null, action: action, startedAt: new Date().toISOString() };
      if (!currentJob.id) {
        currentJob = null;
        setBusyUI(false);
        if (action === 'diagnose') { $('diag-status').textContent = '诊断未开始：没有收到任务标识。'; }
        showActionNotice(meta.label + '未开始：服务端没有返回任务标识。');
        refreshNow();
        return;
      }
      updateElapsed();
      pollJob(currentJob.id, 0);
    }, function (err) {
      setBusyUI(false);
      if (action === 'diagnose') { $('diag-status').textContent = '诊断未能开始，请查看提示后重试。'; }
      if (err && err.kind === 'network') { handleApiError(err); return; }
      if (err && err.status === 401) { showSessionScreen('expired'); return; }
      showActionNotice(meta.label + '未能开始：' + errorText(err));
    });
  }

  function pollJob(id, failures) {
    api('/api/jobs/' + encodeURIComponent(id)).then(function (data) {
      if (!currentJob || currentJob.id !== id) { return; }
      if (data && data.status === 'running') {
        window.setTimeout(function () { pollJob(id, 0); }, 1000);
        return;
      }
      finishJob(data);
    }, function (err) {
      if (!currentJob || currentJob.id !== id) { return; }
      if (err && err.status === 401) { showSessionScreen('expired'); return; }
      if (err && err.status === 404) {
        if (currentJob.action === 'diagnose') { $('diag-status').textContent = '无法查询诊断结果，请重新运行检查。'; }
        currentJob = null;
        setBusyUI(false);
        showActionNotice('无法查询该任务的状态，请以总览状态为准。');
        refreshNow();
        return;
      }
      var count = (failures || 0) + 1;
      if (err && err.kind === 'network') { $('offline-banner').hidden = false; }
      window.setTimeout(function () { pollJob(id, count); }, 2000);
    });
  }

  function finishJob(data) {
    var action = (data && data.action) || (currentJob && currentJob.action) || '';
    var meta = ACTIONS[action] || { label: action };
    var success = data ? data.success : null;
    var code = data && data.code ? data.code : '';
    currentJob = null;
    setBusyUI(false);
    if (action === 'browse') {
      if (success === true && data.result && data.result.selectedPath) {
        applyBrowsePath(data.result.selectedPath);
      } else if (success === true) {
        announce('未选择文件夹。');
      } else {
        showActionNotice(meta.label + '未完成' + (code ? '（' + code + '）' : '') + '。');
      }
    } else if (action === 'check') {
      if (success === true && data.result) {
        renderCheckResult(data.result);
        announce('检查运行条件已完成。');
      } else {
        showActionNotice(meta.label + '未完成' + (code ? '（' + code + '）' : '') + '。');
      }
    } else if (action === 'diagnose') {
      if (success === true && data.result) {
        renderDiagResult(data.result);
        $('diag-status').textContent = '诊断检查已完成。';
        announce('诊断检查已完成。');
      } else {
        $('diag-status').textContent = '诊断检查未完成，请查看提示后重试。';
        showActionNotice(meta.label + '未完成' + (code ? '（' + code + '）' : '') + '。');
      }
    } else if (success === true) {
      announce(meta.label + '已完成。');
    } else if (success === false) {
      showActionNotice(meta.label + '未完成' + (code ? '（' + code + '）' : '') + '，请看总览状态与提示。');
    } else {
      announce(meta.label + '已结束，没有返回结果。');
    }
    refreshNow();
  }

  /* ---- 设置页 ---- */

  var SETUP_FIELDS = ['displayName', 'installDir', 'stateDir', 'logDir', 'componentSourceDir', 'helperSourceDir', 'pollIntervalSec'];

  /* 收在“高级设置”折叠区里的字段;报错时自动展开,保证错误可见 */
  var ADVANCED_FIELDS = { installDir: true, stateDir: true, logDir: true, pollIntervalSec: true };

  function fieldInput(name) { return $('set-' + name); }
  function fieldError(name) { return $('err-' + name); }

  function clearFieldErrors() {
    for (var i = 0; i < SETUP_FIELDS.length; i++) {
      var node = fieldError(SETUP_FIELDS[i]);
      if (node) {
        node.textContent = '';
        node.hidden = true;
      }
      var input = fieldInput(SETUP_FIELDS[i]);
      if (input) { input.removeAttribute('aria-invalid'); }
    }
  }

  function showFieldError(name, text) {
    var names = String(name || '').split(',');
    if (names.length > 1) {
      for (var n = 0; n < names.length; n++) { showFieldError(names[n], text); }
      return;
    }
    name = names[0].replace(/^settings\./, '');
    var node = fieldError(name);
    var input = fieldInput(name);
    if (node) {
      node.textContent = text;
      node.hidden = false;
    }
    if (input) { input.setAttribute('aria-invalid', 'true'); }
    if (ADVANCED_FIELDS[name]) {
      var box = $('advanced-settings');
      if (box) { box.open = true; }
    }
  }

  function setFormStatus(text, kind) {
    var node = $('form-status');
    node.textContent = text || '';
    node.className = 'form-status' + (kind ? ' form-status--' + kind : '');
  }

  function dirtyCount() { return Object.keys(dirtyNames).length; }

  function updateDirtyUI() {
    $('btn-revert').hidden = dirtyCount() === 0;
    if (dirtyCount() > 0) {
      setFormStatus('有未保存的更改。');
    } else {
      setFormStatus('');
    }
    backgroundNoteShown = false;
    refreshActionButtons(); /* Save 的启用态跟随 dirty 重算 */
  }

  function setFormInputsDisabled(disabled) {
    var pathsLocked = layoutChangesLocked();
    for (var i = 0; i < SETUP_FIELDS.length; i++) {
      var name = SETUP_FIELDS[i];
      var input = fieldInput(name);
      if (input) {
        input.disabled = disabled;
        input.readOnly = pathsLocked && (name === 'installDir' || name === 'stateDir' || name === 'logDir');
      }
    }
    var hint = $('layout-lock-hint');
    if (hint) { hint.hidden = !pathsLocked; }
  }

  function renderSetupForm() {
    if (!settingsInfo || !settingsInfo.settings) { return; }
    var settings = settingsInfo.settings;
    for (var i = 0; i < SETUP_FIELDS.length; i++) {
      var name = SETUP_FIELDS[i];
      var input = fieldInput(name);
      if (!input) { continue; }
      if (dirtyNames[name]) { continue; } /* 不覆盖正在编辑的字段 */
      input.value = settings[name] === null || settings[name] === undefined ? '' : String(settings[name]);
    }
  }

  function loadSettings(silent) {
    return api('/api/settings').then(function (data) {
      settingsInfo = data;
      renderSetupForm();
      clearFieldErrors();
      if (!silent) { setFormStatus(''); }
      refreshActionButtons();
      schedulePoll(); /* 轮询间隔可能变化 */
    }, function (err) {
      if (!silent) { handleApiError(err); }
    });
  }

  function maybeSyncSettings(s) {
    if (!settingsInfo || !s) { return; }
    var serverRev = s.settingsRevision;
    if (!serverRev || !settingsInfo.revision) { return; }
    if (serverRev === settingsInfo.revision) { return; }
    if (dirtyCount() > 0) {
      if (!backgroundNoteShown) {
        backgroundNoteShown = true;
        setFormStatus('后台设置已被更新；你的未保存修改仍保留，可“放弃更改”后重新加载。');
      }
      return;
    }
    loadSettings(true);
  }

  function markDirty(name) {
    dirtyNames[name] = true;
    updateDirtyUI();
  }

  function revertSettings() {
    dirtyNames = Object.create(null);
    renderSetupForm();
    clearFieldErrors();
    updateDirtyUI();
  }

  function absolutePathRe() { return /^[A-Za-z]:[\\/].+/; }

  function validateLocal(settings) {
    var problems = [];
    if (!settings.displayName || !String(settings.displayName).trim()) {
      problems.push(['displayName', '必填。']);
    }
    var required = ['installDir', 'stateDir', 'logDir'];
    for (var i = 0; i < required.length; i++) {
      var name = required[i];
      var value = String(settings[name] || '').trim();
      if (!value) { problems.push([name, '必填。']); }
      else if (!absolutePathRe().test(value)) { problems.push([name, FIELD_TEXT.invalidPath]); }
    }
    var optional = ['componentSourceDir', 'helperSourceDir'];
    for (var j = 0; j < optional.length; j++) {
      var optName = optional[j];
      var optValue = String(settings[optName] || '').trim();
      if (optValue && !absolutePathRe().test(optValue)) {
        problems.push([optName, FIELD_TEXT.invalidPath]);
      }
    }
    var poll = Number(settings.pollIntervalSec);
    if (!(poll >= 1 && poll <= 10 && Math.floor(poll) === poll)) {
      problems.push(['pollIntervalSec', '请输入 1–10 的整数。']);
    }
    return problems;
  }

  function readForm() {
    var fields = $('setup-form').elements;
    var settings = {};
    for (var i = 0; i < SETUP_FIELDS.length; i++) {
      var name = SETUP_FIELDS[i];
      var input = fields.namedItem(name);
      settings[name] = input ? input.value : '';
      if (name !== 'displayName' && name !== 'pollIntervalSec') {
        settings[name] = String(settings[name]).trim().replace(/\//g, '\\');
      }
    }
    settings.displayName = String(settings.displayName || '').trim();
    settings.pollIntervalSec = Number(String(settings.pollIntervalSec || '').trim() || '0');
    return settings;
  }

  function saveSettings(event) {
    event.preventDefault();
    if (controlsLocked() || dirtyCount() === 0) { return; }
    var settings = readForm();
    clearFieldErrors();
    var problems = validateLocal(settings);
    if (problems.length) {
      for (var k = 0; k < problems.length; k++) { showFieldError(problems[k][0], problems[k][1]); }
      setFormStatus('请更正标红的字段。', 'error');
      return;
    }
    saveInFlight = true;
    setFormInputsDisabled(true);
    refreshActionButtons();
    var body = { revision: settingsInfo.revision, settings: settings };
    api('/api/settings', { method: 'POST', body: body }).then(function (data) {
      saveInFlight = false;
      settingsInfo = data;
      dirtyNames = Object.create(null);
      renderSetupForm();
      clearFieldErrors();
      setFormInputsDisabled(false);
      updateDirtyUI();
      setFormStatus('设置已保存。', 'ok');
      announce('设置已保存。');
      schedulePoll();
    }, function (err) {
      /* 无论成败,先解锁,再按 busy+dirty+capabilities 重算按钮态 */
      saveInFlight = false;
      setFormInputsDisabled(false);
      refreshActionButtons();
      if (err && err.status === 401) { showSessionScreen('expired'); return; }
      if (err && err.status === 409) {
        var code = String(err.code || '');
        api('/api/settings').then(function (latest) {
          settingsInfo = latest;
          renderSetupForm();
          if (code === 'RuntimeActive') {
            setFormStatus(ERROR_TEXT.RuntimeActive, 'error');
          } else if (/revis/i.test(code)) {
            setFormStatus('设置已在其他窗口被更新。已加载最新编号，你的修改仍保留，请再次点击“保存设置”。', 'error');
          } else {
            setFormStatus('暂时无法保存：可能正有操作进行。请稍后再保存。', 'error');
          }
        }, function () {
          setFormStatus('暂时无法保存：设置编号已变化且刷新失败，请稍后重试。', 'error');
        });
        return;
      }
      if (err && err.fields && err.fields.length) {
        for (var i = 0; i < err.fields.length; i++) {
          var f = err.fields[i];
          var text = FIELD_TEXT[f.code] || '这个值不符合要求。';
          showFieldError(f.field, text);
        }
        setFormStatus('请更正标红的字段。', 'error');
        return;
      }
      setFormStatus('保存失败：' + errorText(err), 'error');
    });
  }

  function browseField(name) {
    if (busyFlag) { return; }
    pendingBrowseField = name;
    runAction('browse', { field: name });
  }

  function applyBrowsePath(pathValue) {
    var name = pendingBrowseField;
    pendingBrowseField = null;
    if (!name) { return; }
    var input = fieldInput(name);
    if (input) {
      input.value = pathValue;
      markDirty(name);
    }
    announce('已选择文件夹。');
  }

  /* ---- 连接指南 ---- */

  function renderAddresses(s) {
    var ul = $('address-list');
    var empty = $('guide-empty');
    var addresses = (s && s.addresses) || [];
    var key = addresses.join('|');
    if (key === renderAddresses.lastKey) {
      return; /* 地址未变化时不重建,保留“已复制”反馈 */
    }
    renderAddresses.lastKey = key;
    clearNode(ul);
    if (!addresses.length) {
      empty.hidden = false;
      return;
    }
    empty.hidden = true;
    for (var i = 0; i < addresses.length; i++) {
      var addr = String(addresses[i]);
      var li = el('li', { class: 'addr-item' });
      li.appendChild(el('code', { text: addr }));
      var btn = el('button', { type: 'button', class: 'btn btn--quiet', text: '复制' });
      bindCopy(btn, addr);
      li.appendChild(btn);
      ul.appendChild(li);
    }
  }

  function bindCopy(btn, addr) {
    btn.addEventListener('click', function () {
      var done = function () {
        announce('已复制 ' + addr);
        btn.textContent = '已复制';
        window.setTimeout(function () { btn.textContent = '复制'; }, 1500);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(addr).then(done, function () { legacyCopy(addr, done); });
      } else {
        legacyCopy(addr, done);
      }
    });
  }

  function legacyCopy(text, done) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', 'readonly');
    ta.style.position = 'absolute';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* 忽略 */ }
    document.body.removeChild(ta);
    done();
  }

  /* ---- 诊断与检查 ---- */

  function renderCheckResult(result) {
    $('check-panel').hidden = false;
    var readyNode = $('check-ready');
    readyNode.textContent = result && result.ready
      ? '结论：目前具备运行条件。'
      : '结论：尚未完全就绪，见下方各项。';
    renderCheckItems($('check-list'), result && result.checks);
  }

  function renderDiagResult(result) {
    lastDiagResult = result || null;
    $('diag-panel').hidden = false;
    renderCheckItems($('diag-summary'), result && result.checks);
    var summary = result && result.summary;
    if (summary) {
      var line = '通过 ' + Number(summary.passed || 0) + ' · 警告 ' + Number(summary.warnings || 0) + ' · 失败 ' + Number(summary.failed || 0);
      if (result.generatedAt) { line += '（生成于 ' + fmtClock(result.generatedAt) + '）'; }
      var note = el('li', { text: line });
      $('diag-summary').appendChild(note);
    }
  }

  function downloadDiagSummary() {
    if (!lastDiagResult) { return; }
    var blob = new window.Blob([JSON.stringify(lastDiagResult, null, 2)], { type: 'application/json' });
    var url = window.URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    var stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    a.download = 'gs-console-diagnose-' + stamp + '.json';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.setTimeout(function () { window.URL.revokeObjectURL(url); }, 1000);
    announce('已开始下载诊断摘要。');
  }

  /* ---- 演示场景 ---- */

  function applyScenario() {
    if (controlsLocked()) { return; }
    var value = $('scenario-select').value;
    api('/api/demo/scenario', { method: 'POST', body: { scenario: value } }).then(function () {
      announce('演示场景已切换。');
      refreshNow();
    }, function (err) {
      if (err && err.status === 401) { showSessionScreen('expired'); return; }
      announce('场景切换失败：' + errorText(err));
    });
  }

  /* ---- 视图切换 ---- */

  function switchView(name) {
    if (name === currentView) { return; }
    if (saveInFlight) { announce('正在保存设置，请稍候。'); return; }
    if (currentView === 'setup' && dirtyCount() > 0 && name !== 'setup') {
      confirmDialog({
        title: '放弃未保存的更改？',
        text: '设置页有未保存的更改，离开后将丢失这些修改。',
        confirmLabel: '放弃更改并离开',
        danger: true
      }).then(function (ok) {
        if (ok) {
          dirtyNames = Object.create(null);
          renderSetupForm();
          updateDirtyUI();
          doSwitch(name);
        }
      });
      return;
    }
    doSwitch(name);
  }

  function doSwitch(name) {
    currentView = name;
    var views = ['overview', 'setup', 'guide', 'diagnostics'];
    for (var i = 0; i < views.length; i++) {
      var section = $('view-' + views[i]);
      if (section) { section.hidden = views[i] !== name; }
    }
    var buttons = document.querySelectorAll('.nav__btn');
    for (var j = 0; j < buttons.length; j++) {
      if (buttons[j].getAttribute('data-view') === name) {
        buttons[j].setAttribute('aria-current', 'page');
      } else {
        buttons[j].removeAttribute('aria-current');
      }
    }
    if (name === 'setup' && !settingsInfo) { loadSettings(); }
    var heading = $(name === 'overview' ? 'overview-title' : name + '-title');
    if (heading) { heading.focus(); }
  }

  /* ---- 事件与启动 ---- */

  function wireEvents() {
    var navButtons = document.querySelectorAll('.nav__btn');
    for (var i = 0; i < navButtons.length; i++) {
      navButtons[i].addEventListener('click', function (event) {
        switchView(event.currentTarget.getAttribute('data-view'));
      });
    }
    $('btn-start').addEventListener('click', function () { handleActionClick('start'); });
    $('btn-stop').addEventListener('click', function () { handleActionClick('stop'); });
    $('btn-more').addEventListener('click', function () {
      var panel = $('more-actions');
      var willShow = panel.hidden;
      if (willShow) { renderMoreActions(stateData || {}, (stateData && stateData.capabilities) || {}, true); }
      panel.hidden = !willShow;
      $('btn-more').setAttribute('aria-expanded', String(willShow));
    });
    $('btn-diagnose').addEventListener('click', function () {
      if (busyFlag) { return; }
      $('diag-status').textContent = '正在运行诊断检查…';
      runAction('diagnose');
    });
    $('btn-diag-download').addEventListener('click', downloadDiagSummary);
    $('setup-form').addEventListener('submit', saveSettings);
    $('btn-revert').addEventListener('click', revertSettings);
    $('btn-browse-component').addEventListener('click', function () { browseField('componentSourceDir'); });
    $('btn-browse-helper').addEventListener('click', function () { browseField('helperSourceDir'); });
    var form = $('setup-form');
    form.addEventListener('input', function (event) {
      var target = event.target;
      if (target && target.name) { markDirty(target.name); }
    });
    $('scenario-apply').addEventListener('click', applyScenario);
    $('offline-retry').addEventListener('click', function () {
      refreshNow();
    });
    $('session-retry').addEventListener('click', function () { window.location.reload(); });
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && !$('app').hidden) { refreshNow(); }
    });
    window.addEventListener('beforeunload', function (event) {
      if (dirtyCount() > 0) {
        event.preventDefault();
        event.returnValue = '';
      }
    });
    window.setInterval(updateElapsed, 1000);
  }

  function initModeBadge() {
    var badge = $('mode-badge');
    badge.hidden = false;
    if (mode === MODE_DEMO) {
      badge.textContent = '演示模式';
      badge.className = 'badge badge--demo';
      $('demo-banner').hidden = false;
    } else {
      badge.textContent = '本机';
      badge.className = 'badge';
    }
  }

  function boot() {
    sessionToken = readSessionToken();
    initModeBadge();
    wireEvents();
    if (mode === MODE_DEMO || sessionToken) {
      $('app').hidden = false;
      $('session-screen').hidden = true;
      refreshActionButtons();
      loadSettings();
      pollState();
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
