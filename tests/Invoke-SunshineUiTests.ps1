#Requires -Version 5.1
<#
.SYNOPSIS
    Contract checks for the Sunshine first-run frontend:
    product/gs-sunshine.html, product/gs-sunshine.css, product/gs-sunshine.js
    and the root Start-GsController-Sunshine.cmd entry.

.DESCRIPTION
    Verifies the SUNSHINE-BACKEND-CONTRACT frontend invariants that can be
    checked without a server:
    - Files exist, are strict UTF-8 decodable and have no BOM; the CMD entry
      is pure ASCII with CRLF endings.
    - HTML carries data-mode="__GS_MODE__", zh-CN lang, a UTF-8 charset, a
      self-only CSP meta, both stylesheet links and the sunshine script.
    - The only external links are the three fixed official URLs, each with
      target="_blank" rel="noopener noreferrer"; no link ever carries the
      session token and JS never rewrites hrefs.
    - The page has no credential inputs (no input/textarea/form), no iframe,
      no legacy runtime controls and no legacy API references.
    - JS calls only GET /api/sunshine/status, always sends X-Gs-Session,
      stores the token under the gs-console-session sessionStorage key and
      strips the #session fragment.
    - CSS is brace-balanced, reuses the shared var(--) tokens, keeps the
      focus-visible and 600px mobile contract and has no external url().
    - Behavior smoke (optional, needs node.exe): stub DOM + fetch covering
      status success/false/null/401/404/network/demo, fixed links, no
      polling and no overclaiming pill labels. All expectations are ASCII
      (Chinese built from char codes); the harness file is written to TEMP.

    Everything is read-only static analysis or an in-process stub; no server,
    no real Sunshine install, no runtime/service/device actions. Exits 0 only
    when every test passes and at least one ran.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$htmlPath = Join-Path $repoRoot 'product\gs-sunshine.html'
$cssPath = Join-Path $repoRoot 'product\gs-sunshine.css'
$jsPath = Join-Path $repoRoot 'product\gs-sunshine.js'
$cmdPath = Join-Path $repoRoot 'Start-GsController-Sunshine.cmd'

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

$fixedUrls = @(
    'https://github.com/LizardByte/Sunshine/releases/latest',
    'https://localhost:47990',
    'https://moonlight-stream.org'
)

Invoke-Test 'SunshineUi.FilesExistStrictUtf8NoBom' {
    foreach ($path in @($htmlPath, $cssPath, $jsPath)) {
        Assert-True (Test-Path $path) "missing file: $path"
        $text = Read-StrictUtf8 -Path $path
        Assert-True ($text.Length -gt 0) "empty file: $path"
    }
    Assert-True (Test-Path $cmdPath) "missing entry: $cmdPath"
}

Invoke-Test 'SunshineUi.CmdEntryAsciiCrlfAndFixedArgument' {
    $bytes = [System.IO.File]::ReadAllBytes($cmdPath)
    Assert-True ($bytes.Length -gt 0) 'CMD is empty'
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    Assert-Equal 0 @($nonAscii).Count 'CMD must be pure ASCII'
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    Assert-True ($text.Contains("`r`n")) 'CMD must use CRLF line endings'
    Assert-True ($text.Contains('product\gs-console.vbs')) 'CMD must call product\gs-console.vbs'
    Assert-True ($text.Contains('"%GsConsole%" Sunshine')) 'CMD must pass the fixed Sunshine argument to the VBS'
    $startMatches = @([regex]::Matches($text, 'start "" "%GsScriptHost%" "%GsConsole%" Sunshine\s*\r\n'))
    Assert-Equal 1 @($startMatches).Count 'CMD must start the VBS with exactly one argument: Sunshine'
    Assert-True ($text.Contains('Sysnative')) 'CMD must keep the x64 Sysnative forwarding'
    foreach ($banned in @('Legacy', '-Backend', '%1', '%2', '%*', '%~1', 'pause=n')) {
        Assert-True (-not $text.Contains($banned)) "CMD must not pass through arbitrary input: $banned"
    }
}

Invoke-Test 'SunshineUi.HtmlModePlaceholderEncodingAndAssets' {
    $html = Read-StrictUtf8 -Path $htmlPath
    Assert-True ($html.Contains('<html lang="zh-CN">')) 'html lang must be zh-CN'
    Assert-True ($html.Contains('charset="utf-8"')) 'charset utf-8 meta required'
    Assert-True ($html.Contains('data-mode="__GS_MODE__"')) 'body data-mode placeholder required'
    Assert-True ($html.Contains("default-src 'self'")) 'CSP meta default-src self required'
    Assert-True ($html.Contains('href="/gs-console.css"')) 'base stylesheet link required'
    Assert-True ($html.Contains('href="/gs-sunshine.css"')) 'sunshine stylesheet link required'
    Assert-True ($html.IndexOf('href="/gs-console.css"') -lt $html.IndexOf('href="/gs-sunshine.css"')) 'base stylesheet must load before the sunshine additions'
    Assert-True ($html.Contains('src="/gs-sunshine.js"')) 'sunshine script src required'
    Assert-True ($html.Contains('<title>GsController Sunshine')) 'title must mark Sunshine mode'
    Assert-True ($html.Contains('id="mode-badge"')) 'mode badge required'
    Assert-True ($html.Contains('id="demo-banner"')) 'demo banner required'
}

Invoke-Test 'SunshineUi.HtmlFixedOfficialLinksOnly' {
    $html = Read-StrictUtf8 -Path $htmlPath
    $anchors = @([regex]::Matches($html, '<a\b[^>]*\bhref="(https?://[^"]+)"[^>]*>'))
    Assert-Equal 3 @($anchors).Count 'exactly three external anchors expected'
    $hrefs = @($anchors | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $expected = @($fixedUrls | Sort-Object)
    for ($i = 0; $i -lt 3; $i++) {
        Assert-Equal $expected[$i] $hrefs[$i] "anchor href must be a fixed official URL (index $i)"
        Assert-True ($anchors[$i].Value.Contains('target="_blank"')) "anchor must open in a new tab: $($anchors[$i].Value)"
        Assert-True ($anchors[$i].Value.Contains('rel="noopener noreferrer"')) "anchor must carry noopener noreferrer: $($anchors[$i].Value)"
    }
    $allUrls = @([regex]::Matches($html, 'https?://[A-Za-z0-9./:_-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    Assert-Equal 3 @($allUrls).Count 'no other http(s) references may appear in the HTML'
    foreach ($url in $allUrls) {
        Assert-True ($fixedUrls -contains $url) "unexpected URL in HTML: $url"
    }
    Assert-True (-not $html.Contains('session=')) 'HTML must never embed a session token'
}

Invoke-Test 'SunshineUi.HtmlStaticGuideWorksWithoutJs' {
    $html = Read-StrictUtf8 -Path $htmlPath
    Assert-True ($html.Contains('<noscript>')) 'noscript hint required'
    Assert-True ($html.Contains('JavaScript')) 'noscript hint must mention JavaScript'
    Assert-True ($html.Contains('class="sun-steps"')) 'three-step guide list required'
    $stepsPos = $html.IndexOf('class="sun-steps"')
    $appPos = $html.IndexOf('<div id="app" hidden>')
    Assert-True ($stepsPos -ge 0 -and $appPos -gt $stepsPos) 'the static guide must not live inside the JS-gated app container'
    foreach ($id in @('btn-refresh', 'check-status', 'status-facts', 'live-region', 'offline-retry', 'session-retry')) {
        Assert-True ($html.Contains('id="' + $id + '"')) "HTML is missing required element: $id"
    }
}

Invoke-Test 'SunshineUi.HtmlNoCredentialsNoEmbedNoRuntimeControls' {
    foreach ($path in @($htmlPath, $jsPath)) {
        $text = Read-StrictUtf8 -Path $path
        foreach ($banned in @('<input', '<textarea', '<form', 'type="password"', 'autocomplete')) {
            Assert-True (-not $text.Contains($banned)) "credential input surface forbidden: $banned in $path"
        }
    }
    $html = Read-StrictUtf8 -Path $htmlPath
    Assert-True (-not $html.Contains('<iframe')) 'embedding external pages is forbidden'
    foreach ($banned in @('/api/actions', '/api/state', '/api/settings', '/api/jobs', '/api/demo/scenario',
            'btn-start', 'btn-stop', 'btn-more', 'autostart', 'deploy', 'scenario-select')) {
        Assert-True (-not $html.Contains($banned)) "legacy runtime control or API must not appear in HTML: $banned"
    }
    $js = Read-StrictUtf8 -Path $jsPath
    foreach ($banned in @('/api/actions', '/api/state', '/api/settings', '/api/jobs', '/api/demo/scenario', "'POST'")) {
        Assert-True (-not $js.Contains($banned)) "legacy runtime API or mutation must not appear in JS: $banned"
    }
}

Invoke-Test 'SunshineUi.HtmlNoInlineScriptStyleOrHandlers' {
    $html = Read-StrictUtf8 -Path $htmlPath
    $inlineScripts = [regex]::Matches($html, '<script(?![^>]*\bsrc=)[^>]*>')
    Assert-Equal 0 @($inlineScripts).Count 'no inline <script> blocks allowed'
    $styleAttrs = [regex]::Matches($html, '\sstyle="')
    Assert-Equal 0 @($styleAttrs).Count 'no inline style attributes allowed'
    $onHandlers = [regex]::Matches($html, '\son[a-z]+\s=')
    Assert-Equal 0 @($onHandlers).Count 'no inline event handler attributes allowed'
}

Invoke-Test 'SunshineUi.JsApiEndpointAllowlist' {
    $js = Read-StrictUtf8 -Path $jsPath
    $found = @([regex]::Matches($js, "'(/api/[^']*)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-Equal 1 @($found).Count 'JS must reference exactly one API endpoint'
    Assert-Equal '/api/sunshine/status' $found[0] 'JS endpoint must be /api/sunshine/status'
}

Invoke-Test 'SunshineUi.JsSessionContract' {
    $js = Read-StrictUtf8 -Path $jsPath
    Assert-True ($js.Contains("'gs-console-demo'")) 'demo token constant required'
    Assert-True ($js.Contains('X-Gs-Session')) 'X-Gs-Session header required'
    Assert-True ($js.Contains('gs-console-session')) 'sessionStorage key required'
    Assert-True ($js.Contains('#session=')) 'fragment parsing required'
    Assert-True ($js.Contains('history.replaceState')) 'fragment must be removed from the URL'
    Assert-True ($js.Contains('sessionStorage')) 'sessionStorage usage required'
    Assert-True ($js.Contains("credentials: 'omit'")) 'requests must omit credentials'
}

Invoke-Test 'SunshineUi.JsStatusFieldContract' {
    $js = Read-StrictUtf8 -Path $jsPath
    foreach ($field in @('installed', 'managementPortOpen', 'pairingStatus', 'streamingStatus', 'observedAt', "'notChecked'")) {
        Assert-True ($js.Contains($field)) "JS must render the contract status field: $field"
    }
}

Invoke-Test 'SunshineUi.JsNoDangerousApisAndNoLinkRewrites' {
    $js = Read-StrictUtf8 -Path $jsPath
    foreach ($pattern in @('innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'document.cookie', 'new Function', 'localStorage')) {
        $hits = [regex]::Matches($js, [regex]::Escape($pattern))
        Assert-Equal 0 @($hits).Count "forbidden API in JS: $pattern"
    }
    foreach ($pattern in @("setAttribute('href'", '.href', 'window.open', 'location.assign', 'location.replace')) {
        Assert-True (-not $js.Contains($pattern)) "JS must never rewrite or open links: $pattern"
    }
}

Invoke-Test 'SunshineUi.JsIdsExistInHtml' {
    $js = Read-StrictUtf8 -Path $jsPath
    $html = Read-StrictUtf8 -Path $htmlPath
    $ids = @([regex]::Matches($js, "\$\('([A-Za-z][A-Za-z0-9-]*)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True ($ids.Count -ge 10) 'expected at least 10 literal element ids in JS'
    foreach ($id in $ids) {
        Assert-True ($html.Contains('id="' + $id + '"')) "HTML is missing element id: $id"
    }
}

Invoke-Test 'SunshineUi.CssStructureTokensAndContract' {
    $css = Read-StrictUtf8 -Path $cssPath
    $open = @([regex]::Matches($css, '\{')).Count
    $close = @([regex]::Matches($css, '\}')).Count
    Assert-Equal $open $close 'CSS braces are not balanced'
    Assert-True ($css.Contains('var(--')) 'CSS must reuse the shared design tokens via var(--)'
    Assert-True ($css.Contains(':focus-visible')) 'focus-visible styles required'
    Assert-True ($css.Contains('max-width: 600px')) 'mobile breakpoint required (375px fit)'
    Assert-True ($css.Contains('@media')) 'responsive media queries required'
    $externalUrls = [regex]::Matches($css, 'url\(\s*["'']?https?://')
    Assert-Equal 0 @($externalUrls).Count 'no external url() allowed in CSS'
    Assert-True (-not $css.Contains('#F5F7FB')) 'CSS must not redefine shared tokens'
}

Invoke-Test 'SunshineUi.BehaviorSmokeViaNode' {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host 'SKIP SunshineUi.BehaviorSmokeViaNode :: node.exe not found'
        return
    }
    $tempJs = Join-Path $env:TEMP ('gs-sunshine-ui-behavior-' + [guid]::NewGuid().ToString('N') + '.js')
    $harness = @'
'use strict';
/* Behavior smoke for gs-sunshine.js: stub DOM + fetch, run boot, exercise
   refresh, 401/404/network paths and demo mode. ASCII only; Chinese
   expectations are built from char codes. Never touches a real server,
   a real Sunshine install or the product runtime. */
var fs = require('fs');
var vm = require('vm');

var code = fs.readFileSync(process.env.GS_SUNSHINE_JS, 'utf8');
var failures = 0;
var doneCount = 0;
var TOTAL = 7;

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
  node.querySelectorAll = function () { return []; };
  node.focus = function () {};
  Object.defineProperty(node, 'firstChild', {
    get: function () { return node.children.length ? node.children[0] : null; }
  });
  return node;
}

var IDS = ['app', 'session-screen', 'session-title', 'session-text', 'session-retry',
  'mode-badge', 'demo-banner', 'offline-banner', 'offline-retry', 'btn-refresh',
  'check-status', 'status-facts', 'live-region'];

var HIDDEN_IDS = ['app', 'session-screen', 'demo-banner', 'offline-banner'];

var FIXED_LINKS = [
  'https://github.com/LizardByte/Sunshine/releases/latest',
  'https://localhost:47990',
  'https://moonlight-stream.org'
];

function okJson(fixture) {
  return function () {
    return {
      ok: true,
      status: 200,
      json: function () { return Promise.resolve({ ok: true, data: fixture }); }
    };
  };
}

function errJson(status, code) {
  return function () {
    return {
      ok: false,
      status: status,
      json: function () { return Promise.resolve({ ok: false, error: { code: code, message: 'x' } }); }
    };
  };
}

function makeDoc(bodyMode, hash, respond) {
  var els = {};
  IDS.forEach(function (id) { els[id] = makeEl('div'); });
  HIDDEN_IDS.forEach(function (id) { els[id].hidden = true; });
  var anchors = FIXED_LINKS.map(function (href) {
    var a = makeEl('a');
    a.className = 'btn';
    a.setAttribute('href', href);
    a.setAttribute('target', '_blank');
    a.setAttribute('rel', 'noopener noreferrer');
    return a;
  });
  var w = {
    calls: [],
    sessionStore: {},
    setItemCalls: [],
    historyCalls: 0,
    fetch: function (path, init) {
      w.calls.push({
        path: path,
        method: (init && init.method) || 'GET',
        headers: (init && init.headers) || {}
      });
      if (respond === 'netfail') {
        return Promise.reject(new Error('network down'));
      }
      return Promise.resolve(respond(path, init));
    },
    setTimeout: function () { return 0; },
    clearTimeout: function () {},
    setInterval: function () { return 0; },
    clearInterval: function () {},
    sessionStorage: {
      getItem: function (k) {
        return Object.prototype.hasOwnProperty.call(w.sessionStore, k) ? w.sessionStore[k] : null;
      },
      setItem: function (k, v) { w.setItemCalls.push(k + '=' + v); w.sessionStore[k] = v; }
    },
    location: {
      hash: hash || '',
      pathname: '/gs-sunshine.html',
      search: '',
      reload: function () { w.reloaded = true; }
    },
    history: { replaceState: function () { w.historyCalls++; } },
    addEventListener: function () {}
  };
  var doc = {
    els: els,
    window: w,
    anchors: anchors,
    readyState: 'complete',
    hidden: false,
    body: { getAttribute: function (a) { return a === 'data-mode' ? bodyMode : null; } },
    getElementById: function (id) {
      return Object.prototype.hasOwnProperty.call(els, id) ? els[id] : null;
    },
    createElement: function (t) { return makeEl(t); },
    createTextNode: function (t) { return { nodeType: 3, text: String(t) }; },
    addEventListener: function () {},
    querySelectorAll: function () { return []; }
  };
  return doc;
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
    isNaN: isNaN
  };
}

function flush() {
  var p = Promise.resolve();
  for (var i = 0; i < 30; i++) {
    p = p.then(function () { return new Promise(function (r) { setImmediate(r); }); });
  }
  return p;
}

/* Chinese expectations built from char codes so this harness stays ASCII */
function zh() {
  var out = [];
  for (var i = 0; i < arguments.length; i++) { out.push(String.fromCharCode(arguments[i])); }
  return out.join('');
}
var ZH_DETECTED = zh(0x5DF2, 0x68C0, 0x6D4B, 0x5230);      /* yi jian ce dao */
var ZH_NOTDETECTED = zh(0x672A, 0x68C0, 0x6D4B, 0x5230);   /* wei jian ce dao */
var ZH_RESPONSIVE = zh(0x6709, 0x54CD, 0x5E94);            /* you xiang ying */
var ZH_NORESPONSE = zh(0x65E0, 0x54CD, 0x5E94);            /* wu xiang ying */
var ZH_NOTCHECKED = zh(0x672A, 0x68C0, 0x67E5);            /* wei jian cha */
var ZH_UNKNOWN = zh(0x672A, 0x77E5);                       /* wei zhi */
var ZH_DONE = zh(0x68C0, 0x67E5, 0x5B8C, 0x6210);          /* jian cha wan cheng */
var ZH_DEMO = zh(0x6F14, 0x793A);                          /* yan shi */
var ZH_CUSTOM = zh(0x81EA, 0x5B9A, 0x4E49);                /* zi ding yi */
var FORBIDDEN_LABELS = [
  zh(0x5DF2, 0x914D, 0x5BF9),         /* claimed-paired */
  zh(0x4E32, 0x6D41, 0x5C31, 0x7EEA), /* claimed-streaming-ready */
  zh(0x914D, 0x5BF9, 0x6210, 0x529F), /* claimed-pairing-success */
  zh(0x4E32, 0x6D41, 0x53EF, 0x7528), /* claimed-streaming-available */
  zh(0x5DF2, 0x9A8C, 0x8BC1),         /* claimed-verified */
  zh(0x5B89, 0x88C5, 0x5B8C, 0x6210)  /* claimed-install-complete */
];

function pillLabels(els) {
  var facts = els['status-facts'].children;
  var labels = [];
  for (var i = 1; i < facts.length; i += 2) {
    if (facts[i].children.length > 0) { labels.push(facts[i].children[0].textContent); }
  }
  return labels;
}

function pillClasses(els) {
  var facts = els['status-facts'].children;
  var classes = [];
  for (var i = 1; i < facts.length; i += 2) {
    if (facts[i].children.length > 0) { classes.push(String(facts[i].children[0].className)); }
  }
  return classes;
}

function forbidLabels(labels, name) {
  expect(labels.length === 4, name + ': four status pills expected, got ' + labels.length);
  labels.forEach(function (label) {
    FORBIDDEN_LABELS.forEach(function (bad) {
      expect(label !== bad, name + ': pill must not overclaim: ' + label.charCodeAt(0));
    });
  });
}

function runScenario(name, bodyMode, hash, respond, assertions) {
  var doc = makeDoc(bodyMode, hash, respond);
  var sandbox = makeSandbox(doc);
  try {
    vm.runInNewContext(code, sandbox, { filename: 'gs-sunshine.js' });
  } catch (e) {
    failures++;
    console.log('BEHAVIOR-FAIL ' + name + ' :: eval: ' + String(e));
    finish();
    return;
  }
  flush().then(function () {
    var result;
    try {
      result = Promise.resolve(assertions(doc));
    } catch (e) {
      failures++;
      console.log('BEHAVIOR-FAIL ' + name + ' :: ' + String(e && e.message ? e.message : e));
      finish();
      return;
    }
    result.then(function () {
      console.log('BEHAVIOR-PASS ' + name);
    }, function (e) {
      failures++;
      console.log('BEHAVIOR-FAIL ' + name + ' :: ' + String(e && e.message ? e.message : e));
    }).then(finish);
  });
}

function finish() {
  doneCount++;
  if (doneCount >= TOTAL) {
    if (failures === 0) { console.log('ALL-BEHAVIOR-OK'); process.exit(0); }
    console.log('ALL-BEHAVIOR-FAILED');
    process.exit(1);
  }
}

var liveFixture = {
  backend: 'sunshine', mode: 'live', observedAt: '2026-11-07T10:00:00Z',
  installed: true, managementPortOpen: true,
  pairingStatus: 'notChecked', streamingStatus: 'notChecked',
  managementUrl: 'https://localhost:47990',
  downloadUrl: 'https://github.com/LizardByte/Sunshine/releases/latest',
  clientUrl: 'https://moonlight-stream.org'
};

runScenario('live-ok', 'live', '#session=abc123', okJson(liveFixture), function (doc) {
  var els = doc.els;
  var w = doc.window;
  expect(els['app'].hidden === false, 'app must be visible with a session token');
  expect(els['session-screen'].hidden === true, 'session screen must stay hidden with a token');
  var facts = els['status-facts'].children;
  expect(facts.length === 10, 'status facts must render 5 dt/dd pairs, got ' + facts.length);
  var classes = pillClasses(els);
  expect(classes.length === 4, 'four status pills expected');
  expect(classes[0].indexOf('diag-pill--ready') >= 0, 'installed=true must style as ready');
  expect(classes[1].indexOf('diag-pill--ready') >= 0, 'open port must style as ready');
  expect(classes[2].indexOf('diag-pill--unknown') >= 0, 'pairing must stay notChecked/unknown');
  expect(classes[3].indexOf('diag-pill--unknown') >= 0, 'streaming must stay notChecked/unknown');
  expect(facts[1].children[0].textContent === ZH_DETECTED, 'installed pill label must be the detected hint');
  expect(facts[3].children[0].textContent === ZH_RESPONSIVE, 'port pill label must be the responsive hint');
  expect(facts[5].children[0].textContent === ZH_NOTCHECKED, 'pairing pill must say not checked');
  expect(facts[9].textContent.length > 0, 'observedAt must render');
  expect(els['check-status'].textContent.indexOf(ZH_DONE) >= 0, 'completion status line required');
  forbidLabels(pillLabels(els), 'live-ok');
  expect(w.calls.length === 1, 'exactly one status call at boot, got ' + w.calls.length);
  expect(w.calls[0].path === '/api/sunshine/status', 'must call the sunshine status endpoint');
  expect(w.calls[0].method === 'GET', 'status must be fetched with GET');
  expect(w.calls[0].headers['X-Gs-Session'] === 'abc123', 'session header must carry the fragment token');
  var stored = false;
  w.setItemCalls.forEach(function (entry) {
    if (entry === 'gs-console-session=abc123') { stored = true; }
  });
  expect(stored, 'fragment token must land in sessionStorage under gs-console-session');
  expect(w.historyCalls === 1, 'the #session fragment must be removed from the URL');
  doc.anchors.forEach(function (a) {
    expect(FIXED_LINKS.indexOf(a.attrs.href) >= 0, 'official link must stay fixed');
    expect(String(a.attrs.href).indexOf('abc123') < 0, 'links must never carry the session token');
    expect(a.attrs.rel === 'noopener noreferrer', 'rel must stay noopener noreferrer');
    expect(a.attrs.target === '_blank', 'links must open in a new tab');
  });
  els['btn-refresh'].listeners['click'][0]();
  return flush().then(function () {
    expect(w.calls.length === 2, 'refresh button issues exactly one more call, got ' + w.calls.length);
    return flush().then(function () {
      expect(w.calls.length === 2, 'no background polling may run');
    });
  });
});

runScenario('live-missing', 'live', '#session=abc123', okJson({
  backend: 'sunshine', mode: 'live', observedAt: '2026-11-07T10:00:00Z',
  installed: false, managementPortOpen: false,
  pairingStatus: 'notChecked', streamingStatus: 'notChecked'
}), function (doc) {
  var els = doc.els;
  var classes = pillClasses(els);
  expect(classes[0].indexOf('diag-pill--missing') >= 0, 'installed=false must style as missing');
  expect(classes[1].indexOf('diag-pill--missing') >= 0, 'closed port must style as missing');
  expect(els['status-facts'].children[1].children[0].textContent === ZH_NOTDETECTED, 'not-detected label required');
  expect(els['status-facts'].children[3].children[0].textContent === ZH_NORESPONSE, 'no-response label required');
  expect(els['status-facts'].children[1].children[1].text.indexOf(ZH_CUSTOM) >= 0,
    'missing program file must mention a possibly custom install location');
  forbidLabels(pillLabels(els), 'live-missing');
});

runScenario('live-unknown', 'live', '#session=abc123', okJson({
  backend: 'sunshine', mode: 'live', observedAt: '2026-11-07T10:00:00Z',
  installed: null, managementPortOpen: null,
  pairingStatus: 'notChecked', streamingStatus: 'notChecked'
}), function (doc) {
  var labels = pillLabels(doc.els);
  expect(labels[0] === ZH_UNKNOWN, 'null installed must render as unknown');
  expect(labels[1] === ZH_UNKNOWN, 'null port must render as unknown');
  expect(labels[2] === ZH_NOTCHECKED, 'pairing stays notChecked');
  expect(labels[3] === ZH_NOTCHECKED, 'streaming stays notChecked');
  forbidLabels(labels, 'live-unknown');
});

runScenario('unauthorized', 'live', '#session=abc123', errJson(401, 'Unauthorized'), function (doc) {
  var els = doc.els;
  expect(els['session-screen'].hidden === false, '401 must show the session screen');
  expect(els['app'].hidden === true, '401 must hide the status container');
  expect(els['session-title'].textContent.length > 0, 'session title text required');
  expect(els['offline-banner'].hidden === true, 'offline banner must stay hidden on 401');
  var text = els['session-text'].textContent;
  var trayIdx = text.indexOf(zh(0x6253, 0x5F00, 0x63A7, 0x5236, 0x53F0)); /* open via tray menu */
  expect(trayIdx >= 0, 'session guidance must lead with the start-menu/tray reopen path');
  var cmdIdx = text.indexOf('Start-GsController-Sunshine.cmd');
  expect(cmdIdx < 0 || cmdIdx > trayIdx,
    'the source-only CMD entry may only be mentioned after the menu/tray guidance');
});

runScenario('network-failure', 'live', '#session=abc123', 'netfail', function (doc) {
  var els = doc.els;
  expect(els['offline-banner'].hidden === false, 'network failure must show the offline banner');
  expect(els['session-screen'].hidden === true, 'session screen must stay hidden');
  expect(els['app'].hidden === false, 'status container must stay visible');
});

runScenario('demo-mode', 'demo', '', okJson({
  backend: 'sunshine', mode: 'demo', observedAt: '2026-11-07T10:00:00Z',
  installed: true, managementPortOpen: true,
  pairingStatus: 'notChecked', streamingStatus: 'notChecked'
}), function (doc) {
  var els = doc.els;
  var w = doc.window;
  expect(els['demo-banner'].hidden === false, 'demo banner must be visible in demo mode');
  expect(String(els['mode-badge'].className).indexOf('badge--demo') >= 0, 'badge must be demo-styled');
  expect(els['check-status'].textContent.indexOf(ZH_DEMO) >= 0, 'status line must flag demo data');
  expect(w.calls.length >= 1 && w.calls[0].headers['X-Gs-Session'] === 'gs-console-demo',
    'demo requests must carry the pinned demo token');
  expect(w.setItemCalls.length === 0, 'demo mode must not touch sessionStorage');
  expect(w.historyCalls === 0, 'demo mode must not rewrite history');
  forbidLabels(pillLabels(els), 'demo-mode');
});

runScenario('endpoint-404', 'live', '#session=abc123', errJson(404, 'NotFound'), function (doc) {
  var els = doc.els;
  expect(els['app'].hidden === false, '404 must keep the status container visible');
  expect(els['check-status'].textContent.length > 0, '404 must surface a status message');
  expect(els['session-screen'].hidden === true, '404 is not a session failure');
  expect(els['offline-banner'].hidden === true, '404 is not an offline state');
});
'@
    Set-Content -Path $tempJs -Value $harness -Encoding Ascii
    $env:GS_SUNSHINE_JS = $jsPath
    try {
        $output = & node $tempJs 2>&1
        $exit = $LASTEXITCODE
        foreach ($line in @($output)) { Write-Host "$line" }
        Assert-Equal 0 $exit 'node behavior smoke must exit 0'
        Assert-True (@($output | Where-Object { $_ -like 'BEHAVIOR-FAIL*' }).Count -eq 0) 'behavior failures present'
    } finally {
        Remove-Item -Force $tempJs -ErrorAction SilentlyContinue
        Remove-Item Env:\GS_SUNSHINE_JS -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Summary: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
