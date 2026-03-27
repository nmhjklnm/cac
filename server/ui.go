package main

const adminHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AnideaAI Server 管理后台</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh}
.login-wrap{display:flex;align-items:center;justify-content:center;min-height:100vh}
.login-box{background:#1e293b;padding:2rem;border-radius:12px;width:340px;box-shadow:0 4px 24px rgba(0,0,0,.3)}
.login-box h2{text-align:center;margin-bottom:1.5rem;color:#38bdf8}
.login-box input{width:100%;padding:.75rem;border:1px solid #334155;border-radius:8px;background:#0f172a;color:#e2e8f0;font-size:1rem;margin-bottom:1rem}
.login-box button{width:100%;padding:.75rem;border:none;border-radius:8px;background:#38bdf8;color:#0f172a;font-size:1rem;font-weight:600;cursor:pointer}
.login-box button:hover{background:#7dd3fc}
.app{display:none;max-width:1100px;margin:0 auto;padding:1.5rem}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:1.5rem}
.header h1{font-size:1.5rem;color:#38bdf8}
.header button{padding:.5rem 1rem;border:1px solid #475569;border-radius:8px;background:transparent;color:#94a3b8;cursor:pointer;font-size:.875rem}
.header button:hover{border-color:#38bdf8;color:#38bdf8}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin-bottom:1.5rem}
.stat-card{background:#1e293b;padding:1.25rem;border-radius:10px;text-align:center}
.stat-card .num{font-size:2rem;font-weight:700;color:#38bdf8}
.stat-card .label{font-size:.875rem;color:#64748b;margin-top:.25rem}
.toolbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem}
.btn-add{padding:.5rem 1.25rem;border:none;border-radius:8px;background:#22c55e;color:#fff;font-weight:600;cursor:pointer;font-size:.875rem}
.btn-add:hover{background:#16a34a}
table{width:100%;border-collapse:collapse;background:#1e293b;border-radius:10px;overflow:hidden}
th,td{padding:.75rem 1rem;text-align:left;font-size:.875rem}
th{background:#334155;color:#94a3b8;font-weight:600;text-transform:uppercase;font-size:.75rem;letter-spacing:.05em}
td{border-bottom:1px solid #1e293b}
tr:hover td{background:#263347}
.badge{display:inline-block;padding:.15rem .6rem;border-radius:999px;font-size:.75rem;font-weight:600}
.badge-on{background:#166534;color:#4ade80}
.badge-off{background:#7f1d1d;color:#fca5a5}
.badge-active{background:#1e3a5f;color:#38bdf8}
.actions button{padding:.3rem .7rem;border:1px solid #475569;border-radius:6px;background:transparent;color:#94a3b8;cursor:pointer;font-size:.75rem;margin-right:.25rem}
.actions button:hover{border-color:#38bdf8;color:#38bdf8}
.actions button.del:hover{border-color:#ef4444;color:#ef4444}
.mono{font-family:"SF Mono",Monaco,Consolas,monospace;font-size:.8rem}
.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:100;align-items:center;justify-content:center}
.modal-overlay.show{display:flex}
.modal{background:#1e293b;padding:2rem;border-radius:12px;width:520px;max-width:90vw}
.modal h3{margin-bottom:1.25rem;color:#38bdf8}
.modal label{display:block;font-size:.875rem;color:#94a3b8;margin-bottom:.25rem}
.modal input,.modal select{width:100%;padding:.6rem;border:1px solid #334155;border-radius:8px;background:#0f172a;color:#e2e8f0;font-size:.9rem;margin-bottom:.75rem}
.modal-btns{display:flex;justify-content:flex-end;gap:.5rem;margin-top:.5rem}
.modal-btns button{padding:.5rem 1.25rem;border:none;border-radius:8px;cursor:pointer;font-weight:600;font-size:.875rem}
.modal-btns .cancel{background:#475569;color:#e2e8f0}
.modal-btns .save{background:#38bdf8;color:#0f172a}
.toast{position:fixed;top:1rem;right:1rem;padding:.75rem 1.25rem;border-radius:8px;font-size:.875rem;z-index:200;opacity:0;transition:opacity .3s}
.toast.show{opacity:1}
.toast.ok{background:#166534;color:#4ade80}
.toast.err{background:#7f1d1d;color:#fca5a5}
.input-row{display:flex;gap:.5rem;margin-bottom:.75rem}
.input-row input{margin-bottom:0;flex:1}
.input-row button{padding:.5rem .75rem;border:1px solid #475569;border-radius:8px;background:transparent;color:#94a3b8;cursor:pointer;font-size:.8rem;white-space:nowrap}
.input-row button:hover{border-color:#38bdf8;color:#38bdf8}
.check-result{font-size:.8rem;margin:-0.5rem 0 .75rem;padding:.5rem .75rem;border-radius:6px}
.check-result.ok{background:#166534;color:#4ade80}
.check-result.fail{background:#7f1d1d;color:#fca5a5}
.check-result.loading{background:#1e3a5f;color:#38bdf8}
.auth-card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:1.25rem;margin-bottom:.75rem;position:relative}
.auth-card.pending{border-left:3px solid #f59e0b}
.auth-card.approved{border-left:3px solid #22c55e;opacity:.6}
.auth-card.failed,.auth-card.expired{border-left:3px solid #64748b;opacity:.5}
.auth-card .auth-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem}
.auth-card .auth-token{font-family:monospace;color:#38bdf8;font-size:.9rem}
.auth-card .auth-time{color:#64748b;font-size:.8rem}
.auth-card .auth-url{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:.5rem .75rem;font-family:monospace;font-size:.75rem;color:#94a3b8;word-break:break-all;margin-bottom:.75rem;max-height:60px;overflow-y:auto}
.auth-card .auth-actions{display:flex;gap:.5rem;align-items:center}
.auth-card .auth-actions input{flex:1;padding:.5rem;border:1px solid #334155;border-radius:6px;background:#0f172a;color:#e2e8f0;font-size:.85rem}
.auth-card .auth-actions button{padding:.5rem 1rem;border:none;border-radius:6px;font-weight:600;cursor:pointer;font-size:.85rem;white-space:nowrap}
.auth-card .btn-approve{background:#22c55e;color:#fff}
.auth-card .btn-approve:hover{background:#16a34a}
.auth-card .btn-copy{background:#475569;color:#e2e8f0;font-size:.75rem;padding:.3rem .6rem}
.auth-card .auth-status{font-size:.8rem;font-weight:600}
.auth-card .auth-status.s-pending{color:#f59e0b}
.auth-card .auth-status.s-approved{color:#22c55e}
.auth-card .auth-status.s-failed{color:#ef4444}
.auth-card .auth-status.s-expired{color:#64748b}
.auth-empty{color:#64748b;font-size:.9rem;text-align:center;padding:2rem;background:#1e293b;border-radius:10px}
</style>
</head>
<body>

<div id="toast" class="toast"></div>

<div id="loginWrap" class="login-wrap">
  <div class="login-box">
    <h2>🔐 AnideaAI Server</h2>
    <input type="password" id="loginPass" placeholder="管理密码" onkeydown="if(event.key==='Enter')doLogin()">
    <button onclick="doLogin()">登 录</button>
  </div>
</div>

<div id="app" class="app">
  <div class="header">
    <h1>AnideaAI Server 管理后台</h1>
    <button onclick="doLogout()">退出登录</button>
  </div>

  <div class="stats">
    <div class="stat-card"><div class="num" id="statTotal">0</div><div class="label">Token 总数</div></div>
    <div class="stat-card"><div class="num" id="statActive">0</div><div class="label">活跃连接</div></div>
    <div class="stat-card"><div class="num" id="statEnabled">0</div><div class="label">已启用</div></div>
  </div>

  <!-- Auth Requests Section -->
  <div id="authReqSection" style="margin-bottom:2rem">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem">
      <h2 style="font-size:1.15rem;color:#f59e0b">待授权请求</h2>
      <span style="color:#64748b;font-size:.8rem" id="authReqCount"></span>
    </div>
    <div id="authReqList"></div>
  </div>

  <div class="toolbar">
    <div style="color:#64748b;font-size:.875rem" id="lastRefresh"></div>
    <button class="btn-add" onclick="showAddModal()">+ 添加 Token</button>
  </div>

  <table>
    <thead>
      <tr><th>Token</th><th>后端代理</th><th>SK</th><th>备注</th><th>状态</th><th>凭证</th><th>代理</th><th>连接</th><th>最后心跳</th><th>最后使用</th><th>操作</th></tr>
    </thead>
    <tbody id="tokenList"></tbody>
  </table>
</div>

<div id="modalOverlay" class="modal-overlay">
  <div class="modal">
    <h3 id="modalTitle">添加 Token</h3>
    <input type="hidden" id="editId">
    <label>Token <span style="font-size:.75rem;color:#64748b">（自动生成）</span></label>
    <div class="input-row">
      <input type="text" id="fToken" readonly style="background:#1a2332;color:#64748b">
      <button onclick="regenToken()" id="btnRegenToken">🔄</button>
    </div>
    <label>后端代理 <span style="font-size:.75rem;color:#64748b">支持 ip:port:user:pass 或完整URL</span></label>
    <div class="input-row">
      <input type="text" id="fBackend" placeholder="45.56.156.162:6052:user:pass">
      <button onclick="testBackend()" id="btnTest">检测</button>
    </div>
    <div id="checkResult" class="check-result" style="display:none"></div>
    <label>SessionKey <span style="font-size:.75rem;color:#64748b">(用于自动 OAuth 认证)</span></label>
    <input type="text" id="fSK" placeholder="sk-ant-... (可选)">
    <label>备注</label>
    <input type="text" id="fNote" placeholder="可选备注">
    <div id="enabledWrap" style="display:none;margin-bottom:.75rem">
      <label>状态</label>
      <select id="fEnabled"><option value="1">启用</option><option value="0">禁用</option></select>
    </div>
    <div class="modal-btns">
      <button class="cancel" onclick="hideModal()">取消</button>
      <button class="save" onclick="saveToken()">保存</button>
    </div>
  </div>
</div>

<script>
let authToken = localStorage.getItem('anideaai_auth') || '';
let refreshTimer;

function api(method, path, body) {
  const opts = { method, headers: { 'Authorization': 'Bearer ' + authToken, 'Content-Type': 'application/json' } };
  if (body) opts.body = JSON.stringify(body);
  return fetch(path, opts).then(r => {
    if (r.status === 401) { doLogout(); throw new Error('unauthorized'); }
    return r.json();
  });
}

function toast(msg, ok) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast show ' + (ok ? 'ok' : 'err');
  setTimeout(() => t.className = 'toast', 2500);
}

function doLogin() {
  const pass = document.getElementById('loginPass').value;
  fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: pass }) })
    .then(r => r.json())
    .then(d => {
      if (d.error) { toast(d.error, false); return; }
      authToken = d.token;
      localStorage.setItem('anideaai_auth', authToken);
      showApp();
    });
}

function doLogout() {
  authToken = '';
  localStorage.removeItem('anideaai_auth');
  document.getElementById('app').style.display = 'none';
  document.getElementById('loginWrap').style.display = 'flex';
  if (refreshTimer) clearInterval(refreshTimer);
}

function showApp() {
  document.getElementById('loginWrap').style.display = 'none';
  document.getElementById('app').style.display = 'block';
  loadTokens();
  loadAuthRequests();
  refreshTimer = setInterval(() => { loadTokens(); loadAuthRequests(); }, 5000);
}

function loadTokens() {
  api('GET', '/api/tokens').then(tokens => {
    const tbody = document.getElementById('tokenList');
    let totalActive = 0, totalEnabled = 0;
    let html = '';
    tokens.forEach(t => {
      totalActive += t.active_conns;
      if (t.enabled) totalEnabled++;
      const statusBadge = t.enabled ? '<span class="badge badge-on">启用</span>' : '<span class="badge badge-off">禁用</span>';
      const connBadge = t.active_conns > 0 ? '<span class="badge badge-active">' + t.active_conns + ' 活跃</span> / ' + t.total_conns : t.total_conns + '';
      const lastUsed = t.last_used_at ? new Date(t.last_used_at).toLocaleString('zh-CN') : '-';
      const skDisplay = t.sk ? '<span class="badge badge-on">已配置</span>' : '<span style="color:#64748b">-</span>';
      // Credential status badge
      let credBadge = '<span style="color:#64748b">-</span>';
      if (t.cred_status === 'valid') credBadge = '<span class="badge badge-on">有效</span>';
      else if (t.cred_status === 'expired') credBadge = '<span class="badge badge-off">过期</span>';
      else if (t.cred_status === 'missing') credBadge = '<span class="badge badge-off">缺失</span>';
      else if (t.cred_status === 'session_error') credBadge = '<span class="badge badge-off">异常退出</span>';
      // Proxy status badge
      let proxyBadge = '<span style="color:#64748b">-</span>';
      const ipTip = t.proxy_exit_ip ? ' title="出口IP: ' + esc(t.proxy_exit_ip) + '"' : '';
      if (t.proxy_status === 'ok') proxyBadge = '<span class="badge badge-on"' + ipTip + '>正常</span>';
      else if (t.proxy_status === 'unreachable') proxyBadge = '<span class="badge badge-off">不通</span>';
      else if (t.proxy_status === 'ip_mismatch') proxyBadge = '<span class="badge" style="background:#78350f;color:#fbbf24"' + ipTip + '>IP异常</span>';
      // Heartbeat time
      const hbTime = t.last_heartbeat ? new Date(t.last_heartbeat).toLocaleString('zh-CN') : '-';
      html += '<tr>' +
        '<td class="mono">' + esc(t.token) + '</td>' +
        '<td class="mono">' + esc(maskBackend(t.backend)) + '</td>' +
        '<td>' + skDisplay + '</td>' +
        '<td>' + esc(t.note) + '</td>' +
        '<td>' + statusBadge + '</td>' +
        '<td>' + credBadge + '</td>' +
        '<td>' + proxyBadge + '</td>' +
        '<td>' + connBadge + '</td>' +
        '<td style="font-size:.8rem;color:#64748b">' + hbTime + '</td>' +
        '<td style="font-size:.8rem;color:#64748b">' + lastUsed + '</td>' +
        '<td class="actions">' +
          '<button onclick="showEditModal(' + t.id + ',\'' + esc(t.token) + '\',\'' + esc(t.backend) + '\',\'' + esc(t.note) + '\',\'' + esc(t.sk||'') + '\',' + t.enabled + ')">编辑</button>' +
          '<button class="del" onclick="deleteToken(' + t.id + ',\'' + esc(t.token) + '\')">删除</button>' +
        '</td></tr>';
    });
    tbody.innerHTML = html;
    document.getElementById('statTotal').textContent = tokens.length;
    document.getElementById('statActive').textContent = totalActive;
    document.getElementById('statEnabled').textContent = totalEnabled;
    document.getElementById('lastRefresh').textContent = '刷新于 ' + new Date().toLocaleTimeString('zh-CN');
  }).catch(() => {});
}

function maskBackend(url) {
  try {
    const m = url.match(/^(\w+:\/\/)([^@]+)@(.+)$/);
    if (m) return m[1] + '***@' + m[3];
  } catch(e) {}
  return url;
}

function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

function genToken() {
  const arr = new Uint8Array(6);
  crypto.getRandomValues(arr);
  return Array.from(arr, b => b.toString(16).padStart(2, '0')).join('');
}

function regenToken() {
  document.getElementById('fToken').value = genToken();
}

function showAddModal() {
  document.getElementById('modalTitle').textContent = '添加 Token';
  document.getElementById('editId').value = '';
  document.getElementById('fToken').value = genToken();
  document.getElementById('fToken').readOnly = true;
  document.getElementById('fToken').style.color = '#64748b';
  document.getElementById('btnRegenToken').style.display = '';
  document.getElementById('fBackend').value = '';
  document.getElementById('fSK').value = '';
  document.getElementById('fNote').value = '';
  document.getElementById('enabledWrap').style.display = 'none';
  document.getElementById('checkResult').style.display = 'none';
  document.getElementById('modalOverlay').classList.add('show');
}

function showEditModal(id, token, backend, note, sk, enabled) {
  document.getElementById('modalTitle').textContent = '编辑 Token';
  document.getElementById('editId').value = id;
  document.getElementById('fToken').value = token;
  document.getElementById('fToken').readOnly = true;
  document.getElementById('fToken').style.color = '#64748b';
  document.getElementById('btnRegenToken').style.display = 'none';
  document.getElementById('fBackend').value = backend;
  document.getElementById('fSK').value = sk || '';
  document.getElementById('fNote').value = note;
  document.getElementById('fEnabled').value = enabled ? '1' : '0';
  document.getElementById('enabledWrap').style.display = 'block';
  document.getElementById('checkResult').style.display = 'none';
  document.getElementById('modalOverlay').classList.add('show');
}

function hideModal() { document.getElementById('modalOverlay').classList.remove('show'); }

function testBackend() {
  const backend = document.getElementById('fBackend').value.trim();
  if (!backend) { toast('请先输入后端代理地址', false); return; }

  const el = document.getElementById('checkResult');
  el.style.display = 'block';
  el.className = 'check-result loading';
  el.textContent = '⏳ 正在检测，请稍候...';
  document.getElementById('btnTest').disabled = true;

  api('POST', '/api/check-proxy', { backend }).then(d => {
    document.getElementById('btnTest').disabled = false;
    if (d.ok) {
      el.className = 'check-result ok';
      el.textContent = '✓ 协议: ' + d.protocol + '  |  出口IP: ' + d.exit_ip;
      // Auto-update backend field with detected protocol URL
      if (d.protocol && !backend.match(/^(http|https|socks5):\/\//)) {
        // Only update if user didn't specify protocol
        // The server normalizeBackend will handle it on save
      }
    } else {
      el.className = 'check-result fail';
      el.textContent = '✗ ' + (d.error || '检测失败');
    }
  }).catch(() => {
    document.getElementById('btnTest').disabled = false;
    el.className = 'check-result fail';
    el.textContent = '✗ 请求失败';
  });
}

function saveToken() {
  const id = document.getElementById('editId').value;
  const token = document.getElementById('fToken').value.trim();
  const backend = document.getElementById('fBackend').value.trim();
  const sk = document.getElementById('fSK').value.trim();
  const note = document.getElementById('fNote').value.trim();

  if (!backend) { toast('后端代理必填', false); return; }

  if (id) {
    const enabled = document.getElementById('fEnabled').value === '1';
    api('PUT', '/api/tokens/' + id, { backend, note, sk, enabled }).then(d => {
      if (d.error) { toast(d.error, false); return; }
      toast('已更新', true); hideModal(); loadTokens();
    });
  } else {
    api('POST', '/api/tokens', { token, backend, note, sk }).then(d => {
      if (d.error) { toast(d.error, false); return; }
      toast('已添加，Token: ' + (d.token || token), true); hideModal(); loadTokens();
    });
  }
}

function deleteToken(id, token) {
  if (!confirm('确认删除 Token: ' + token + '？')) return;
  api('DELETE', '/api/tokens/' + id).then(d => {
    if (d.error) { toast(d.error, false); return; }
    toast('已删除', true); loadTokens();
  });
}

function loadAuthRequests() {
  api('GET', '/api/auth-requests').then(reqs => {
    const container = document.getElementById('authReqList');
    const pending = reqs.filter(r => r.status === 'pending');
    document.getElementById('authReqCount').textContent = pending.length > 0 ? pending.length + ' 个待处理' : '';

    if (reqs.length === 0) {
      container.innerHTML = '<div class="auth-empty">暂无授权请求</div>';
      return;
    }

    let html = '';
    reqs.forEach(r => {
      const time = new Date(r.created_at).toLocaleString('zh-CN');
      const statusClass = 's-' + r.status;
      const statusText = {pending:'等待授权',approved:'已授权',failed:'失败',expired:'已过期'}[r.status] || r.status;

      html += '<div class="auth-card ' + r.status + '">';
      html += '<div class="auth-header">';
      html += '<div><span class="auth-token">Token: ' + esc(r.token) + '</span> <span class="auth-status ' + statusClass + '">' + statusText + '</span></div>';
      html += '<div class="auth-time">' + time + '</div>';
      html += '</div>';
      html += '<div class="auth-url" id="authUrl' + r.id + '">' + esc(r.auth_url) + '</div>';

      if (r.status === 'pending') {
        html += '<div class="auth-actions">';
        html += '<button class="btn-copy" onclick="copyAuthUrl(' + r.id + ')">复制链接</button>';
        html += '<input type="text" id="codeInput' + r.id + '" placeholder="输入授权 code">';
        html += '<button class="btn-approve" onclick="approveRequest(' + r.id + ')">授权</button>';
        html += '</div>';
      } else if (r.status === 'failed') {
        html += '<div style="color:#ef4444;font-size:.8rem;margin-top:.25rem">错误: ' + esc(r.error) + '</div>';
      }

      html += '</div>';
    });
    container.innerHTML = html;
  }).catch(() => {});
}

function copyAuthUrl(id) {
  const el = document.getElementById('authUrl' + id);
  navigator.clipboard.writeText(el.textContent).then(() => toast('已复制', true)).catch(() => toast('复制失败', false));
}

function approveRequest(id) {
  const code = document.getElementById('codeInput' + id).value.trim();
  if (!code) { toast('请输入授权 code', false); return; }
  api('POST', '/api/auth-requests/' + id + '/approve', { code }).then(d => {
    if (d.error) { toast(d.error, false); return; }
    toast('已授权', true);
    loadAuthRequests();
  });
}

// Auto-login if token exists
if (authToken) {
  api('GET', '/api/tokens').then(() => showApp()).catch(() => doLogout());
}
</script>
</body>
</html>`
