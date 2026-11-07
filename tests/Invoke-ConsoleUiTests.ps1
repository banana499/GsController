#Requires -Version 5.1
<#
.SYNOPSIS
    Static contract checks for the local console frontend assets:
    product/gs-console.html, product/gs-console.css, product/gs-console.js.

.DESCRIPTION
    Verifies the shared LOCAL-CONSOLE-CONTRACT invariants that can be
    checked without a server:
    - Files exist, are strict UTF-8 decodable and have no BOM.
    - HTML carries data-mode="__GS_MODE__", a UTF-8 charset, zh-CN lang,
      a self-only CSP meta, and no inline scripts, inline style attributes
      or external (http/https) resource references.
    - JS uses only the allowlisted /api endpoints, never innerHTML/eval/
      document.write, always sends the X-Gs-Session header, stores the live
      session token in sessionStorage and strips the #session fragment,
      and pins the demo token to gs-console-demo.
    - Every element id read via the JS $() helper exists in the HTML.
    - CSS is brace-balanced, contains prefers-reduced-motion, focus-visible
      and the 900px/600px responsive breakpoints, and no external url().
    - No reference to the support-ZIP tool from the console assets.

    Everything is read-only static analysis; no server, no product actions,
    no Invoke-All. Exits 0 only when every test passes and at least one ran.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$htmlPath = Join-Path $repoRoot 'product\gs-console.html'
$cssPath = Join-Path $repoRoot 'product\gs-console.css'
$jsPath = Join-Path $repoRoot 'product\gs-console.js'

$script:Passed = 0
$script:Failed = 0

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name :: $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "Assertion failed: $Message (expected '$Expected', got '$Actual')" }
}

function Read-StrictUtf8 {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "File has a UTF-8 BOM: $Path"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetString($bytes)
}

Invoke-Test 'ConsoleUi.FilesExistAndStrictUtf8NoBom' {
    foreach ($path in @($htmlPath, $cssPath, $jsPath)) {
        Assert-True (Test-Path $path) "missing file: $path"
        $text = Read-StrictUtf8 -Path $path
        Assert-True ($text.Length -gt 0) "empty file: $path"
    }
}

Invoke-Test 'ConsoleUi.HtmlModePlaceholderAndEncoding' {
    $html = Read-StrictUtf8 -Path $htmlPath
    Assert-True ($html.Contains('<html lang="zh-CN">')) 'html lang must be zh-CN'
    Assert-True ($html.Contains('charset="utf-8"')) 'charset utf-8 meta required'
    Assert-True ($html.Contains('data-mode="__GS_MODE__"')) 'body data-mode placeholder required'
    Assert-True ($html.Contains("default-src 'self'")) 'CSP meta default-src self required'
    Assert-True ($html.Contains('href="/gs-console.css"')) 'stylesheet link required'
    Assert-True ($html.Contains('src="/gs-console.js"')) 'script src required'
}

Invoke-Test 'ConsoleUi.HtmlNoInlineScriptNoInlineStyleNoExternalUrls' {
    $html = Read-StrictUtf8 -Path $htmlPath
    $inlineScripts = [regex]::Matches($html, '<script(?![^>]*\bsrc=)[^>]*>')
    Assert-Equal 0 @($inlineScripts).Count 'no inline <script> blocks allowed'
    $styleAttrs = [regex]::Matches($html, '\sstyle="')
    Assert-Equal 0 @($styleAttrs).Count 'no inline style attributes allowed'
    $external = [regex]::Matches($html, 'https?://')
    Assert-Equal 0 @($external).Count 'no external http(s) references allowed'
    $onHandlers = [regex]::Matches($html, '\son[a-z]+\s=')
    Assert-Equal 0 @($onHandlers).Count 'no inline event handler attributes allowed'
}

Invoke-Test 'ConsoleUi.JsApiEndpointAllowlist' {
    $js = Read-StrictUtf8 -Path $jsPath
    $allowed = @('/api/state', '/api/settings', '/api/actions', '/api/jobs/', '/api/demo/scenario')
    $found = @([regex]::Matches($js, "'(/api/[^']*)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True ($found.Count -gt 0) 'no /api endpoints found in JS'
    foreach ($endpoint in $found) {
        $ok = $false
        foreach ($candidate in $allowed) {
            if ($endpoint -eq $candidate -or ($candidate.EndsWith('/') -and $endpoint.StartsWith($candidate))) { $ok = $true; break }
        }
        Assert-True $ok "endpoint outside allowlist: $endpoint"
    }
    Assert-True ($js.Contains('/api/jobs/')) 'job polling endpoint required'
}

Invoke-Test 'ConsoleUi.JsSessionContract' {
    $js = Read-StrictUtf8 -Path $jsPath
    Assert-True ($js.Contains("'gs-console-demo'")) 'demo token constant required'
    Assert-True ($js.Contains('X-Gs-Session')) 'X-Gs-Session header required'
    Assert-True ($js.Contains('gs-console-session')) 'sessionStorage key required'
    Assert-True ($js.Contains('#session=')) 'fragment parsing required'
    Assert-True ($js.Contains('history.replaceState')) 'fragment must be removed from the URL'
    Assert-True ($js.Contains('sessionStorage')) 'sessionStorage usage required'
}

Invoke-Test 'ConsoleUi.JsNoDangerousApis' {
    $js = Read-StrictUtf8 -Path $jsPath
    foreach ($pattern in @('innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'document.cookie', 'new Function', 'localStorage')) {
        $hits = [regex]::Matches($js, [regex]::Escape($pattern))
        Assert-Equal 0 @($hits).Count "forbidden API in JS: $pattern"
    }
}

Invoke-Test 'ConsoleUi.JsIdsExistInHtml' {
    $js = Read-StrictUtf8 -Path $jsPath
    $html = Read-StrictUtf8 -Path $htmlPath
    $ids = @([regex]::Matches($js, "\$\('([A-Za-z][A-Za-z0-9-]*)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True ($ids.Count -ge 20) 'expected at least 20 literal element ids in JS'
    foreach ($id in $ids) {
        Assert-True ($html.Contains('id="' + $id + '"')) "HTML is missing element id: $id"
    }
}

Invoke-Test 'ConsoleUi.CssStructureAndContract' {
    $css = Read-StrictUtf8 -Path $cssPath
    $open = @([regex]::Matches($css, '\{')).Count
    $close = @([regex]::Matches($css, '\}')).Count
    Assert-Equal $open $close 'CSS braces are not balanced'
    Assert-True ($css.Contains('prefers-reduced-motion')) 'prefers-reduced-motion required'
    Assert-True ($css.Contains(':focus-visible')) 'focus-visible styles required'
    Assert-True ($css.Contains('max-width: 900px')) 'narrow desktop breakpoint required'
    Assert-True ($css.Contains('max-width: 600px')) 'mobile breakpoint required'
    $externalUrls = [regex]::Matches($css, 'url\(\s*["'']?https?://')
    Assert-Equal 0 @($externalUrls).Count 'no external url() allowed in CSS'
    Assert-True ($css.Contains('#F5F7FB')) 'mist-white base color token required'
    Assert-True ($css.Contains('#142C48')) 'deep-sea ink color token required'
}

Invoke-Test 'ConsoleUi.NoSupportZipReference' {
    foreach ($path in @($htmlPath, $cssPath, $jsPath)) {
        $text = Read-StrictUtf8 -Path $path
        Assert-True (-not $text.Contains('gs-support')) "support ZIP tool must not be referenced: $path"
    }
}

Invoke-Test 'ConsoleUi.HtmlRequiredViewSections' {
    $html = Read-StrictUtf8 -Path $htmlPath
    foreach ($id in @('view-overview', 'view-setup', 'view-guide', 'view-diagnostics', 'session-screen', 'confirm-dialog', 'demo-banner', 'offline-banner', 'live-region')) {
        Assert-True ($html.Contains('id="' + $id + '"')) "HTML is missing required section: $id"
    }
}

Invoke-Test 'ConsoleUi.HiddenOverrideAndStyles' {
    $css = Read-StrictUtf8 -Path $cssPath
    Assert-True ($css.Contains('[hidden] { display: none !important; }')) 'global [hidden] display:none override required'
    $rules = [regex]::Matches($css, '([^{}]*\[hidden\][^{}]*)\{([^}]*)\}')
    Assert-True (@($rules).Count -ge 1) 'at least one [hidden] rule expected'
    foreach ($rule in $rules) {
        Assert-True ($rule.Groups[2].Value -match 'display:\s*none') 'every [hidden] rule must set display:none'
    }
    Assert-True ($css.Contains('.columns')) '.columns grid definition required'
    Assert-True ($css.Contains('.check-raw')) 'check details styles required'
}

Invoke-Test 'ConsoleUi.FactsLoopAndHintPreference' {
    $js = Read-StrictUtf8 -Path $jsPath
    Assert-True ($js.Contains('list.appendChild(rows[i]);')) 'facts loop must append flat nodes ([].concat flattens [dt,dd] pairs)'
    Assert-True (-not $js.Contains('rows[i].length')) 'old two-level facts loop must be gone'
    Assert-True ($js.Contains('STATE_HINTS[state] || s.message')) 'Chinese state hints must be preferred over server English message'
    Assert-True ($js.Contains('STATUS_HINTS_CN')) 'Chinese check-status hints table required'
    Assert-True ($js.Contains('appendCheckDetails')) 'raw English must be moved into expandable details'
}

Invoke-Test 'ConsoleUi.SaveInFlightContract' {
    $js = Read-StrictUtf8 -Path $jsPath
    Assert-True ($js.Contains('saveInFlight')) 'independent saveInFlight flag required'
    Assert-True ($js.Contains('setFormInputsDisabled')) 'form inputs must be locked during save'
    Assert-True ($js.Contains('controlsLocked()') -and $js.Contains('locked || noEdits')) 'save must combine the common interaction guard with dirty state'
}

Invoke-Test 'ConsoleUi.BehaviorSmokeViaNode' {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host 'SKIP ConsoleUi.BehaviorSmokeViaNode :: node.exe not found'
        return
    }
    $tempJs = Join-Path $env:TEMP ('gs-console-ui-behavior-' + [guid]::NewGuid().ToString('N') + '.js')
    $harness = @'
'use strict';
/* Behavior smoke for gs-console.js: stub DOM + fetch, run boot + first state
   poll, assert what actually rendered. ASCII only; Chinese expectations are
   written as \u escapes. Never touches a real server or product. */
var fs = require('fs');
var vm = require('vm');

var code = fs.readFileSync(process.env.GS_CONSOLE_JS, 'utf8');
var failures = 0;
var doneCount = 0;

function expect(cond, msg) {
  if (!cond) { throw new Error(msg); }
}

function makeEl(tag) {
  var node = {
    tagName: String(tag || 'div').toUpperCase(),
    children: [],
    attrs: {},
    listeners: {},
    textContent: '',
    className: '',
    value: '',
    hidden: false,
    disabled: false,
    open: false,
    title: ''
  };
  node.setAttribute = function (n, v) { node.attrs[n] = String(v); };
  node.getAttribute = function (n) {
    return Object.prototype.hasOwnProperty.call(node.attrs, n) ? node.attrs[n] : null;
  };
  node.removeAttribute = function (n) { delete node.attrs[n]; };
  node.appendChild = function (c) { node.children.push(c); return c; };
  node.removeChild = function (c) {
    var i = node.children.indexOf(c);
    if (i >= 0) { node.children.splice(i, 1); }
  };
  node.addEventListener = function (t, f) {
    (node.listeners[t] = node.listeners[t] || []).push(f);
  };
  node.removeEventListener = function () {};
  node.querySelectorAll = function (sel) {
    var tag = String(sel).replace(/[^A-Za-z]/g, '').toUpperCase();
    return node.children.filter(function (c) { return c.tagName === tag; });
  };
  node.focus = function () {};
  Object.defineProperty(node, 'firstChild', {
    get: function () { return node.children.length ? node.children[0] : null; }
  });
  Object.defineProperty(node, 'lastChild', {
    get: function () {
      return node.children.length ? node.children[node.children.length - 1] : null;
    }
  });
  return node;
}

var IDS = ['app', 'session-screen', 'session-title', 'session-text', 'session-retry',
  'mode-badge', 'demo-banner', 'offline-banner', 'offline-retry', 'nav-setup',
  'setup-title', 'hero', 'hero-state', 'hero-message', 'hero-elapsed', 'facts-list',
  'next-steps', 'prereq-panel', 'prereq-list', 'check-panel', 'check-ready',
  'check-list', 'btn-start', 'btn-stop', 'btn-more', 'more-actions', 'action-notice',
  'address-list', 'guide-empty', 'btn-diagnose', 'diag-status', 'diag-panel',
  'diag-summary', 'btn-diag-download', 'setup-form', 'btn-save', 'btn-revert',
  'form-status', 'btn-browse-component', 'btn-browse-helper', 'scenario-select',
  'scenario-apply', 'confirm-dialog', 'confirm-title', 'confirm-text',
  'confirm-details', 'confirm-ok', 'confirm-cancel', 'live-region',
  'set-displayName', 'set-installDir', 'set-stateDir', 'set-logDir',
  'set-componentSourceDir', 'set-helperSourceDir', 'set-pollIntervalSec'];

var FIELDS = ['displayName', 'installDir', 'stateDir', 'logDir',
  'componentSourceDir', 'helperSourceDir', 'pollIntervalSec'];

function settingsFixture() {
  return {
    displayName: 'This PC',
    installDir: 'C:/GsInstall',
    stateDir: 'C:/GsState',
    logDir: 'C:/GsLogs',
    componentSourceDir: '',
    helperSourceDir: '',
    pollIntervalSec: 2
  };
}

function makeWindow(fixture) {
  var w = {
    calls: [],
    pendingSave: null,
    fetch: function (path, init) {
      var method = init && init.method ? init.method : 'GET';
      w.calls.push({ path: path, method: method });
      function wrap(payload) {
        return Promise.resolve({
          ok: true,
          status: 200,
          json: function () { return Promise.resolve(payload); }
        });
      }
      if (path === '/api/settings' && method === 'POST') {
        var resolveFn = null;
        var p = new Promise(function (r) { resolveFn = r; });
        w.pendingSave = { resolve: resolveFn };
        return p.then(function (payload2) { return wrap(payload2); });
      }
      if (path === '/api/settings') {
        return wrap({ ok: true, data: { revision: 1, settings: settingsFixture() } });
      }
      return wrap({ ok: true, data: fixture });
    },
    setTimeout: function () { return 0; },
    clearTimeout: function () {},
    setInterval: function () { return 0; },
    clearInterval: function () {},
    sessionStorage: { getItem: function () { return null; }, setItem: function () {} },
    location: { hash: '', pathname: '/', search: '' },
    history: { replaceState: function () {} },
    addEventListener: function () {},
    Blob: function Blob() {},
    URL: { createObjectURL: function () { return ''; }, revokeObjectURL: function () {} }
  };
  return w;
}

function makeDoc(mode, fixture) {
  var els = {};
  IDS.forEach(function (id) { els[id] = makeEl(id === 'setup-form' ? 'form' : 'div'); });
  /* elements that carry the hidden attribute in the static HTML */
  ['more-actions', 'prereq-panel', 'check-panel', 'diag-panel', 'guide-empty',
    'btn-revert', 'offline-banner', 'demo-banner', 'session-screen', 'app'].forEach(function (id) {
    els[id].hidden = true;
  });
  var inputs = {};
  FIELDS.forEach(function (n) {
    if (!els['set-' + n]) { els['set-' + n] = makeEl('input'); }
    inputs[n] = els['set-' + n];
  });
  els['setup-form'].elements = { namedItem: function (n) {
    return Object.prototype.hasOwnProperty.call(inputs, n) ? inputs[n] : null;
  } };
  var navBtns = ['overview', 'setup', 'guide', 'diagnostics'].map(function (v) {
    var b = makeEl('button');
    b.attrs['data-view'] = v;
    return b;
  });
  var doc = {
    els: els,
    inputs: inputs,
    navBtns: navBtns,
    readyState: 'complete',
    hidden: false,
    body: { getAttribute: function (a) { return a === 'data-mode' ? mode : null; } },
    getElementById: function (id) {
      return Object.prototype.hasOwnProperty.call(els, id) ? els[id] : null;
    },
    querySelectorAll: function (sel) {
      if (sel === '.nav__btn') { return navBtns.slice(); }
      return [];
    },
    createElement: function (t) { return makeEl(t); },
    createTextNode: function (t) { return { nodeType: 3, text: String(t) }; },
    addEventListener: function () {}
  };
  doc.window = makeWindow(fixture);
  return doc;
}

function flush() {
  var p = Promise.resolve();
  for (var i = 0; i < 30; i++) {
    p = p.then(function () { return new Promise(function (r) { setImmediate(r); }); });
  }
  return p;
}

function makeSandbox(doc) {
  return {
    document: doc,
    window: doc.window,
    navigator: {},
    console: console,
    setImmediate: setImmediate,
    Promise: Promise,
    Date: Date,
    JSON: JSON,
    Math: Math,
    Object: Object,
    String: String,
    Number: Number,
    Boolean: Boolean,
    Array: Array,
    RegExp: RegExp,
    encodeURIComponent: encodeURIComponent,
    isNaN: isNaN
  };
}

function runScenario(name, fixture, assertions) {
  var doc = makeDoc('demo', fixture);
  var sandbox = makeSandbox(doc);
  try {
    vm.runInNewContext(code, sandbox, { filename: 'gs-console.js' });
  } catch (e) {
    failures++;
    console.log('BEHAVIOR-FAIL ' + name + ' :: eval: ' + String(e));
    finish();
    return;
  }
  flush().then(function () {
    try {
      assertions(doc.els);
      console.log('BEHAVIOR-PASS ' + name);
    } catch (e) {
      failures++;
      console.log('BEHAVIOR-FAIL ' + name + ' :: ' + String(e && e.message ? e.message : e));
    }
    finish();
  });
}

function finish() {
  doneCount++;
  if (doneCount >= 4) {
    if (failures === 0) { console.log('ALL-BEHAVIOR-OK'); process.exit(0); }
    console.log('ALL-BEHAVIOR-FAILED');
    process.exit(1);
  }
}

var CAPS = { start: true, stop: true, recover: true, check: true, deploy: true,
  diagnose: true, browse: true, autostart: true };

var scenarioA = {
  mode: 'demo', version: 'local-console-preview', displayName: 'This PC',
  state: 'stopped', stateLabel: 'Stopped',
  message: 'Runtime reported: stopped (status file)',
  updatedAt: '2026-11-07T10:00:00Z', isElevated: true,
  addresses: ['192.0.2.10'],
  prerequisites: [
    { id: 'runtime', status: 'ready', code: '', message: 'ok' },
    { id: 'permissions', status: 'ready', code: '', message: 'ok' }
  ],
  capabilities: CAPS,
  autostart: 'disabled', operation: null, lastResult: null, settingsRevision: 1
};

var scenarioB = {
  mode: 'demo', version: 'local-console-preview', displayName: 'This PC',
  state: 'needsSetup', stateLabel: 'NeedsSetup',
  message: 'Runtime config not found on this machine',
  updatedAt: '2026-11-07T10:00:00Z', isElevated: false,
  addresses: [],
  prerequisites: [
    { id: 'runtime', status: 'ready', code: '', message: 'ok' },
    { id: 'permissions', status: 'missing', code: 'PermDenied',
      message: 'Runtime component missing: elevated rights required' }
  ],
  capabilities: { start: true, stop: true, recover: false, check: false,
    deploy: false, diagnose: false, browse: false, autostart: true },
  autostart: 'unknown', operation: null, lastResult: null, settingsRevision: 1
};

/* Chinese expectations built from char codes so this harness stays pure ASCII */
var ZH_STOPPED = String.fromCharCode(0x5DF2, 0x505C, 0x6B62);
var ZH_MISSING = String.fromCharCode(0x7F3A, 0x5931);
var ZH_PERM = String.fromCharCode(0x6743, 0x9650);

function assertA(els) {
  expect(els['app'].hidden === false, 'app should be visible in demo mode');
  expect(els['session-screen'].hidden === true, 'session screen stays hidden with a token');
  expect(els['offline-banner'].hidden === true, 'offline banner hidden after successful poll');
  expect(els['hero'].attrs['data-state'] === 'stopped', 'hero data-state must be stopped');
  expect(els['hero-state'].textContent === ZH_STOPPED, 'hero state label must be Chinese');
  expect(els['hero-message'].textContent.length > 0 &&
    els['hero-message'].textContent.charCodeAt(0) > 127,
    'hero message must start with a Chinese hint, not the English server message');
  expect(els['hero-message'].textContent !== scenarioA.message, 'English message must not be shown verbatim');
  var facts = els['facts-list'].children;
  expect(facts.length === 18, 'facts dl must have 18 children (9 dt + 9 dd), got ' + facts.length);
  expect(facts[0].tagName === 'DT' && facts[1].tagName === 'DD', 'facts children must alternate dt/dd');
  expect(els['btn-start'].disabled === false, 'start button enabled when capability allows');
  expect(els['prereq-panel'].hidden === true, 'all-ready prereq panel must collapse outside needsSetup/error');
}

function assertB(els) {
  expect(els['prereq-panel'].hidden === false, 'missing prerequisite must show the panel');
  expect(els['btn-diagnose'].disabled === true, 'diagnose must stay disabled without capability');
  expect(els['btn-browse-component'].disabled === true, 'browse must stay disabled without capability');
  expect(els['btn-start'].disabled === false, 'start enabled per capability (not blanket-disabled)');
  var items = els['prereq-list'].children;
  expect(items.length === 2, 'two prerequisite items expected');
  var li = items[1];
  var pill = li.children[0];
  expect(String(pill.className).indexOf('diag-pill--missing') >= 0, 'pill styled as missing');
  expect(pill.textContent === ZH_MISSING, 'pill label must be Chinese');
  expect(li.children[1].textContent.indexOf(ZH_PERM) === 0, 'known id must map to Chinese label');
  var englishOutside = li.children.some(function (child) {
    if (child.tagName === 'DETAILS') { return false; }
    return String(child.textContent || child.text || '').indexOf('Runtime component missing') >= 0;
  });
  expect(!englishOutside, 'English message must stay inside the expandable details');
  var detailsNodes = li.children.filter(function (c) { return c.tagName === 'DETAILS'; });
  expect(detailsNodes.length === 1, 'exactly one details expander per item');
  var raw = detailsNodes[0].children.filter(function (c) { return c.tagName === 'PRE'; })[0];
  expect(Boolean(raw) && raw.textContent.indexOf('Runtime component missing') >= 0,
    'original English message preserved in details');
  expect(raw.textContent.indexOf('PermDenied') >= 0, 'failure code stays queryable in details');
}

var scenarioC = {
  mode: 'demo', version: 'local-console-preview', displayName: 'This PC',
  state: 'stopped', stateLabel: 'Stopped', message: 'Runtime reported: stopped',
  updatedAt: '2026-11-07T10:00:00Z', isElevated: true,
  addresses: ['192.0.2.10'],
  prerequisites: [{ id: 'runtime', status: 'ready', code: '', message: 'ok' }],
  capabilities: CAPS,
  autostart: 'disabled', operation: null, lastResult: null, settingsRevision: 1
};

function clickNav(doc, index) {
  var btn = doc.navBtns[index];
  btn.listeners['click'][0]({ currentTarget: btn });
}

/* Save-race: in-flight lock, no double submit, dirty-driven save gating */
function runSaveRace() {
  var doc = makeDoc('demo', scenarioC);
  try {
    vm.runInNewContext(code, makeSandbox(doc), { filename: 'gs-console.js' });
  } catch (e) {
    failures++;
    console.log('BEHAVIOR-FAIL save-race :: eval: ' + String(e));
    finish();
    return;
  }
  flush().then(function () {
    var els = doc.els;
    var w = doc.window;
    expect(w.calls.some(function (c) { return c.path === '/api/settings' && c.method === 'GET'; }), 'settings revision loaded during boot, before actions');
    expect(els['btn-start'].disabled === false, 'start available before saving');
    clickNav(doc, 1); /* open setup view */
    return flush().then(function () {
      expect(els['setup-title'].textContent.length > 0, 'setup view opened');
      expect(els['btn-save'].disabled === true, 'save disabled before any edit');
      expect(els['btn-browse-component'].disabled === false, 'browse enabled per capability');
      doc.inputs['displayName'].value = 'My PC';
      els['setup-form'].listeners['input'][0]({ target: { name: 'displayName' } });
      expect(els['btn-save'].disabled === false, 'save enabled once dirty');
      expect(els['btn-revert'].disabled === false, 'revert enabled once dirty');
      doc.inputs['installDir'].value = 'C:/GsInstall2';
      doc.inputs['stateDir'].value = 'C:/GsState';
      doc.inputs['logDir'].value = 'C:/GsLogs';
      els['setup-form'].listeners['submit'][0]({ preventDefault: function () {} });
      return flush().then(function () {
        expect(els['btn-save'].disabled === true, 'save disabled while save in flight');
        expect(doc.inputs['displayName'].disabled === true, 'inputs locked while save in flight');
        expect(els['btn-browse-component'].disabled === true, 'browse disabled while save in flight');
        expect(els['btn-start'].disabled === true, 'runtime actions disabled while save in flight');
        expect(els['scenario-apply'].disabled === true, 'scenario mutations disabled while save in flight');
        els['setup-form'].listeners['submit'][0]({ preventDefault: function () {} });
        expect(Boolean(w.pendingSave), 'save POST sent once');
        w.pendingSave.resolve({ ok: true, data: { revision: 2, settings: settingsFixture() } });
        return flush().then(function () {
          var posts = w.calls.filter(function (c) {
            return c.path === '/api/settings' && c.method === 'POST';
          });
          expect(posts.length === 1, 'no double submit, got ' + posts.length);
          expect(doc.inputs['displayName'].disabled === false, 'inputs unlocked after save');
          expect(els['btn-save'].disabled === true, 'save disabled again after dirty cleared');
          expect(els['btn-revert'].hidden === true, 'revert hidden after save');
          console.log('BEHAVIOR-PASS save-race');
        });
      });
    });
  }).catch(function (e) {
    failures++;
    console.log('BEHAVIOR-FAIL save-race :: ' + String(e && e.message ? e.message : e));
  }).then(finish);
}

runScenario('demo-stopped', scenarioA, assertA);
runScenario('demo-needsSetup', scenarioB, assertB);
var activeScenario = Object.assign({}, scenarioA, { state: 'streaming' });
runScenario('active-layout-readonly', activeScenario, function (els) {
  ['installDir', 'stateDir', 'logDir'].forEach(function (name) {
    expect(els['set-' + name].readOnly === true, 'active instance path is read-only: ' + name);
  });
  expect(els['set-displayName'].readOnly === false, 'display name remains editable');
  expect(els['set-pollIntervalSec'].readOnly === false, 'poll preference remains editable');
  expect(els['set-helperSourceDir'].readOnly === false, 'redeployment source remains editable');
  expect(els['btn-browse-helper'].disabled === false, 'source picker remains available per capability');
});
runSaveRace();
'@
    Set-Content -Path $tempJs -Value $harness -Encoding Ascii
    $env:GS_CONSOLE_JS = $jsPath
    try {
        $output = & node $tempJs 2>&1
        $exit = $LASTEXITCODE
        foreach ($line in @($output)) { Write-Host "$line" }
        Assert-Equal 0 $exit 'node behavior smoke must exit 0'
        Assert-True (@($output | Where-Object { $_ -like 'BEHAVIOR-FAIL*' }).Count -eq 0) 'behavior failures present'
    } finally {
        Remove-Item -Force $tempJs -ErrorAction SilentlyContinue
        Remove-Item Env:\GS_CONSOLE_JS -ErrorAction SilentlyContinue
    }
}

# ==NEXT==

Write-Host ""
Write-Host "Summary: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
