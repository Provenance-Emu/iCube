// Drag and drop
const zone = document.getElementById('drop-zone');
zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('hover'); });
zone.addEventListener('dragleave', () => zone.classList.remove('hover'));
// Folder-preserving drop: walk dropped directory trees via
// webkitGetAsEntry so a dragged folder uploads each file as
// "Textures/GAME01/tex.png" (the server recreates the subfolder). Dolphin
// loads texture packs and Riivolution mods from subfolders, so the
// relative path is preserved on upload. Falls back to a
// flat list when the browser doesn't expose filesystem entries.
function readAllEntries(reader) {
  return new Promise((resolve, reject) => {
    const out = [];
    const batch = () => reader.readEntries(ents => {
      if (!ents.length) { resolve(out); return; }
      out.push.apply(out, ents); batch();
    }, reject);
    batch();
  });
}
async function walkEntry(entry, out) {
  if (entry.isFile) {
    const file = await new Promise((res, rej) => entry.file(res, rej));
    let p = entry.fullPath || ('/' + file.name);
    if (p.charAt(0) === '/') p = p.slice(1);
    out.push({ file: file, path: p });
  } else if (entry.isDirectory) {
    const ents = await readAllEntries(entry.createReader());
    for (let i = 0; i < ents.length; i++) await walkEntry(ents[i], out);
  }
}
async function collectEntries(entries) {
  const out = [];
  for (let i = 0; i < entries.length; i++) await walkEntry(entries[i], out);
  return out;
}
function toItems(fileList) {
  const out = [];
  for (let i = 0; i < fileList.length; i++) {
    const f = fileList[i];
    out.push({ file: f, path: f.webkitRelativePath || f.name });
  }
  return out;
}

zone.addEventListener('drop', e => {
  e.preventDefault(); zone.classList.remove('hover');
  const items = e.dataTransfer.items;
  let entries = null;
  if (items && items.length && items[0].webkitGetAsEntry) {
    entries = [];
    for (let i = 0; i < items.length; i++) {
      const en = items[i].webkitGetAsEntry();
      if (en) entries.push(en);
    }
  }
  if (entries && entries.length) {
    collectEntries(entries).then(uploadFiles);
  } else {
    uploadFiles(toItems(e.dataTransfer.files));
  }
});

document.getElementById('upload-btn').addEventListener('click', () => {
  document.getElementById('file-input').click();
});
document.getElementById('file-input').addEventListener('change', e => {
  uploadFiles(toItems(e.target.files));
});

// Single shared upload queue + cumulative counters. Each drop/picker
// ADDS to this one queue; a single processor drains it against one
// progress bar. (Previously each uploadFiles() call ran its own loop
// with its own local total, so a second drop spun up a concurrent
// loop and the two fought over the same bar — the count and fill
// bounced between the groups, and whichever finished first hid the
// bar while the other was still uploading.)
const uploadQueue = [];
const maxConcurrent = 4;
let uploading = false;
let totalQueued = 0;   // files in the active batch
let completed = 0;     // files finished in the active batch
let reloadTimer = null;
let uploadSeq = 0;
// Per-XHR byte progress — aggregated for the parallel worker pool.
const inFlight = new Map();
// Steam-style transfer panel state (byte-weighted batch progress).
let batchItems = [];
let batchTotalBytes = 0;
let speedEMA = 0;
let chartSamples = [];
let lastSpeedSample = { t: 0, bytes: 0 };
let chartTimer = null;
let rafPending = false;

function formatBytes(n) {
  n = Number(n) || 0;
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(2) + ' MB';
  return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}
function formatSpeed(bps) {
  if (!bps || bps < 100) return '—';
  return (bps / (1024 * 1024)).toFixed(2) + ' MB/s';
}
function formatETA(seconds) {
  if (!isFinite(seconds) || seconds < 0) return '—';
  seconds = Math.round(seconds);
  if (seconds < 60) return seconds + 's';
  return Math.floor(seconds / 60) + 'm ' + (seconds % 60) + 's';
}
function displayName(path) {
  const i = path.lastIndexOf('/');
  return i < 0 ? path : path.slice(i + 1);
}

function registerBatchItems(files) {
  for (let k = 0; k < files.length; k++) {
    const it = files[k];
    const f = it.file;
    const relPath = it.path || f.name;
    const size = f.size || 0;
    batchItems.push({
      id: batchItems.length + 1,
      name: relPath,
      size: size,
      state: 'waiting',
      loaded: 0
    });
    batchTotalBytes += size;
  }
}

function aggregateUploadedBytes() {
  let bytes = 0;
  for (let i = 0; i < batchItems.length; i++) {
    const item = batchItems[i];
    if (item.state === 'done') bytes += item.size;
    else bytes += item.loaded;
  }
  return bytes;
}

function onProgressTick() {
  if (rafPending) return;
  rafPending = true;
  requestAnimationFrame(function() {
    rafPending = false;
    const uploaded = aggregateUploadedBytes();
    const now = performance.now();
    const dt = (now - lastSpeedSample.t) / 1000;
    if (dt > 0.2 && lastSpeedSample.t > 0) {
      const instant = (uploaded - lastSpeedSample.bytes) / dt;
      speedEMA = speedEMA ? speedEMA * 0.7 + instant * 0.3 : instant;
      lastSpeedSample = { t: now, bytes: uploaded };
    }
    const pct = batchTotalBytes > 0 ? Math.min(100, (uploaded / batchTotalBytes) * 100) : 0;
    const fill = document.getElementById('transfer-fill');
    if (fill) fill.style.width = pct + '%';
    const speedEl = document.getElementById('transfer-speed');
    const etaEl = document.getElementById('transfer-eta');
    const filesEl = document.getElementById('transfer-files');
    const bytesEl = document.getElementById('transfer-bytes');
    if (speedEl) speedEl.textContent = formatSpeed(speedEMA);
    if (etaEl) {
      const remaining = batchTotalBytes - uploaded;
      const eta = speedEMA > 1000 ? remaining / speedEMA : NaN;
      etaEl.textContent = formatETA(eta);
    }
    if (filesEl) filesEl.textContent = completed + '/' + totalQueued;
    if (bytesEl) bytesEl.textContent = formatBytes(uploaded) + ' / ' + formatBytes(batchTotalBytes);
    renderQueue();
  });
}

function renderQueue() {
  const container = document.getElementById('transfer-queue');
  if (!container) return;
  let html = '';
  for (let i = 0; i < batchItems.length; i++) {
    const item = batchItems[i];
    const pct = item.size > 0 ? Math.min(100, (item.loaded / item.size) * 100) : 0;
    let statusText = 'Waiting';
    let statusClass = '';
    if (item.state === 'uploading') { statusText = Math.round(pct) + '%'; statusClass = 'uploading'; }
    else if (item.state === 'done') { statusText = 'Done'; statusClass = 'done'; }
    else if (item.state === 'failed') { statusText = 'Failed'; statusClass = 'failed'; }
    const active = item.state === 'uploading' ? ' active' : '';
    html += '<div class="queue-row' + active + '">' +
      '<span class="queue-name" title="' + escapeHtml(item.name) + '">' + escapeHtml(displayName(item.name)) + '</span>' +
      '<span class="queue-size">' + formatBytes(item.size) + '</span>' +
      '<div class="queue-bar"><div class="queue-bar-fill" style="width:' + pct + '%"></div></div>' +
      '<span class="queue-status ' + statusClass + '">' + statusText + '</span></div>';
  }
  container.innerHTML = html;
}

function drawChart() {
  const canvas = document.getElementById('speed-chart');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;
  ctx.clearRect(0, 0, w, h);
  if (chartSamples.length < 2) return;
  let peak = 0;
  for (let i = 0; i < chartSamples.length; i++) {
    if (chartSamples[i] > peak) peak = chartSamples[i];
  }
  if (peak < 1024) peak = 1024;
  const n = chartSamples.length;
  ctx.beginPath();
  for (let i = 0; i < n; i++) {
    const x = (i / (n - 1)) * w;
    const y = h - (chartSamples[i] / peak) * (h - 4) - 2;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.lineTo(w, h);
  ctx.lineTo(0, h);
  ctx.closePath();
  ctx.fillStyle = 'rgba(74, 144, 217, 0.15)';
  ctx.fill();
  ctx.beginPath();
  for (let i = 0; i < n; i++) {
    const x = (i / (n - 1)) * w;
    const y = h - (chartSamples[i] / peak) * (h - 4) - 2;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.strokeStyle = 'rgba(74, 144, 217, 0.85)';
  ctx.lineWidth = 1.5;
  ctx.stroke();
}

function sampleChart() {
  if (!uploading) return;
  chartSamples.push(speedEMA);
  if (chartSamples.length > 120) chartSamples.shift();
  drawChart();
}

function uploadFiles(files) {
  if (!files || !files.length) return;
  if (reloadTimer) { clearTimeout(reloadTimer); reloadTimer = null; }
  if (!uploading) {
    batchItems = [];
    batchTotalBytes = 0;
    chartSamples = [];
    speedEMA = 0;
    lastSpeedSample = { t: 0, bytes: 0 };
  }
  registerBatchItems(files);
  for (let k = 0; k < files.length; k++) uploadQueue.push(files[k]);
  if (!uploading) {
    totalQueued = uploadQueue.length;
    completed = 0;
  } else {
    totalQueued += files.length;
  }
  if (!uploading) processQueue();
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Throttled live refresh — rebuilding the full HTML page per file was
// dominating multi-file upload time on the device.
async function refreshFileList() {
  try {
    const r = await fetch(location.href, { cache: 'no-store' });
    if (!r.ok) return;
    const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
    const fresh = doc.getElementById('file-list');
    const cur = document.getElementById('file-list');
    if (fresh && cur) cur.innerHTML = fresh.innerHTML;
  } catch (e) { /* transient: the final reload will reconcile */ }
}

function uploadOneFile() {
  return new Promise((resolve) => {
    if (!uploadQueue.length) { resolve(); return; }
    const it = uploadQueue.shift();
    const f = it.file;
    const relPath = it.path || f.name;
    const id = ++uploadSeq;
    const batchItem = batchItems.find(function(b) { return b.state === 'waiting'; });
    if (batchItem) batchItem.state = 'uploading';
    inFlight.set(id, { loaded: 0, total: f.size || 0, name: relPath });

    const url = uploadPutUrl(relPath);
    const xhr = new XMLHttpRequest();
    xhr.upload.onprogress = (e) => {
      const entry = inFlight.get(id);
      if (!entry) return;
      if (e.lengthComputable) {
        entry.loaded = e.loaded;
        entry.total = e.total;
        if (batchItem) batchItem.loaded = e.loaded;
      }
      onProgressTick();
    };
    const finish = (ok) => {
      inFlight.delete(id);
      completed++;
      if (batchItem) {
        batchItem.state = ok ? 'done' : 'failed';
        batchItem.loaded = batchItem.size;
      }
      onProgressTick();
      resolve();
    };
    xhr.onload = () => finish(uploadOkStatus(xhr.status));
    xhr.onerror = () => finish(false);
    xhr.open('PUT', url);
    xhr.setRequestHeader('Overwrite', 'T');
    xhr.send(f);
  });
}

async function processQueue() {
  uploading = true;
  const panel = document.getElementById('transfer-panel');
  const summary = document.getElementById('transfer-summary');
  if (panel) panel.style.display = 'block';
  if (summary) summary.textContent = '';
  lastSpeedSample = { t: performance.now(), bytes: 0 };
  if (!chartTimer) chartTimer = setInterval(sampleChart, 500);
  onProgressTick();

  async function worker() {
    while (uploadQueue.length) {
      await uploadOneFile();
    }
  }

  // Drain the queue; re-loop if a drop lands while workers are finishing.
  do {
    const workers = [];
    for (let i = 0; i < maxConcurrent; i++) workers.push(worker());
    await Promise.all(workers);
  } while (uploadQueue.length > 0);

  // Final directory listing once the whole batch is on disk.
  await refreshFileList();

  uploading = false;
  if (chartTimer) { clearInterval(chartTimer); chartTimer = null; }
  const fill = document.getElementById('transfer-fill');
  if (fill) fill.style.width = '100%';
  if (summary) summary.textContent = 'Done! ' + completed + ' file(s) uploaded.';
  onProgressTick();
  reloadTimer = setTimeout(() => {
    if (panel) panel.style.display = 'none';
    if (fill) fill.style.width = '0%';
    if (summary) summary.textContent = '';
    totalQueued = 0;
    completed = 0;
    batchItems = [];
    batchTotalBytes = 0;
    chartSamples = [];
    speedEMA = 0;
    location.reload();
  }, 2000);
}

// ---- File management: rename / move / delete + drag-drop ----------
const CURRENT_PATH = "{{CURRENT_PATH}}";

function basename(p) {
  const i = p.lastIndexOf('/');
  return i < 0 ? p : p.slice(i + 1);
}
function dirname(p) {
  const i = p.lastIndexOf('/');
  return i < 0 ? '' : p.slice(0, i);
}
function joinPath(dir, name) {
  return dir ? dir + '/' + name : name;
}

// Full path relative to ROM root (respects subfolder browse via CURRENT_PATH).
function relativeUploadPath(relPath) {
  const clean = String(relPath || '').replace(/^\/+/, '');
  return joinPath(CURRENT_PATH, clean);
}

// Raw PUT target — same /files/ prefix as DELETE; hits the fast stream path on the server.
function uploadPutUrl(relPath) {
  const full = relativeUploadPath(relPath);
  return '/files/' + full.split('/').filter(Boolean).map(encodeURIComponent).join('/');
}

function uploadOkStatus(status) {
  return status === 201 || status === 204 || (status >= 200 && status < 300);
}

async function apiMove(src, dst) {
  const r = await fetch('/move', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ src: src, dst: dst })
  });
  if (!r.ok) {
    let msg = 'Move failed';
    try { const j = await r.json(); if (j.error) msg += ': ' + j.error; } catch (e) {}
    alert(msg);
    return false;
  }
  return true;
}

function rowPath(el) { return el.closest('tr').dataset.path; }
function rowName(el) { return el.closest('tr').dataset.name; }

async function renameItem(el) {
  const path = rowPath(el), name = rowName(el);
  const next = prompt('Rename to:', name);
  if (!next || next === name) return;
  if (next.indexOf('/') >= 0) { alert('Name cannot contain "/"'); return; }
  if (await apiMove(path, joinPath(dirname(path), next))) location.reload();
}

async function moveItem(el) {
  const path = rowPath(el), name = rowName(el);
  const dest = prompt('Move to folder (relative path, blank = base):', dirname(path));
  if (dest === null) return;
  const clean = dest.split('/').filter(Boolean).join('/');
  if (await apiMove(path, joinPath(clean, name))) location.reload();
}

async function deleteItem(el) {
  const path = rowPath(el), name = rowName(el);
  if (!confirm('Delete "' + name + '"?')) return;
  const r = await fetch('/files/' + path.split('/').map(encodeURIComponent).join('/'),
                        { method: 'DELETE' });
  if (r.ok) location.reload(); else alert('Delete failed');
}

document.getElementById('new-folder-btn').addEventListener('click', async () => {
  const name = prompt('New folder name:');
  if (!name) return;
  const r = await fetch('/mkdir', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: joinPath(CURRENT_PATH, name) })
  });
  if (r.ok) location.reload(); else alert('Could not create folder');
});

// ---- Right-click context menu ------------------------------------
const menu = document.getElementById('context-menu');
function hideMenu() { menu.style.display = 'none'; }
document.addEventListener('click', hideMenu);
document.addEventListener('scroll', hideMenu, true);

document.querySelectorAll('tr[data-path]').forEach(tr => {
  if (tr.classList.contains('uprow')) return;
  tr.addEventListener('contextmenu', e => {
    e.preventDefault();
    const isDir = tr.dataset.dir === '1';
    const path = tr.dataset.path;
    let html = '';
    if (!isDir) {
      html += '<button data-act="download">&#x2B07;&#xFE0F; Download</button>';
    }
    html += '<button data-act="rename">&#x270F;&#xFE0F; Rename</button>';
    html += '<button data-act="move">&#x1F4E6; Move</button>';
    html += '<button class="danger" data-act="delete">&#x1F5D1;&#xFE0F; Delete</button>';
    menu.innerHTML = html;
    menu.querySelectorAll('button[data-act]').forEach(b => {
      b.addEventListener('click', () => {
        hideMenu();
        if (b.dataset.act === 'rename') renameItem(tr);
        else if (b.dataset.act === 'move') moveItem(tr);
        else if (b.dataset.act === 'delete') deleteItem(tr);
        else if (b.dataset.act === 'download') {
          window.location.href = '/files/' +
            path.split('/').map(encodeURIComponent).join('/');
        }
      });
    });
    menu.style.display = 'block';
    const mw = 170, mh = menu.offsetHeight || 160;
    menu.style.left = Math.min(e.clientX, window.innerWidth - mw) + 'px';
    menu.style.top = Math.min(e.clientY, window.innerHeight - mh) + 'px';
  });
});

// ---- Drag rows onto folders to move; drop OS files onto folders ---
let draggedPath = null;

document.querySelectorAll('tr[draggable="true"]').forEach(tr => {
  tr.addEventListener('dragstart', e => {
    draggedPath = tr.dataset.path;
    tr.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    try { e.dataTransfer.setData('text/plain', draggedPath); } catch (err) {}
  });
  tr.addEventListener('dragend', () => {
    draggedPath = null;
    tr.classList.remove('dragging');
  });
});

document.querySelectorAll('tr.dir-row').forEach(folder => {
  const folderPath = folder.dataset.path; // '' for the ".." row's parent
  folder.addEventListener('dragover', e => {
    // Accept internal row moves and external file drops.
    if (draggedPath && draggedPath === folderPath) return; // onto self
    e.preventDefault();
    e.dataTransfer.dropEffect = draggedPath ? 'move' : 'copy';
    folder.classList.add('drag-target');
  });
  folder.addEventListener('dragleave', () => folder.classList.remove('drag-target'));
  folder.addEventListener('drop', async e => {
    e.preventDefault();
    folder.classList.remove('drag-target');
    // External files → upload into this folder.
    if (e.dataTransfer.files && e.dataTransfer.files.length) {
      await uploadFilesTo(e.dataTransfer.files, folderPath);
      return;
    }
    // Internal row → move into this folder.
    if (draggedPath && draggedPath !== folderPath) {
      const dst = joinPath(folderPath, basename(draggedPath));
      if (await apiMove(draggedPath, dst)) location.reload();
    }
  });
});

// Upload helper that targets an arbitrary folder (used by folder drops).
async function uploadFilesTo(files, folderPath) {
  const target = folderPath
    ? '/upload?path=' + folderPath.split('/').map(encodeURIComponent).join('/')
    : '/upload';
  for (let k = 0; k < files.length; k++) {
    const fd = new FormData();
    fd.append('files[]', files[k], files[k].name);
    await fetch(target, { method: 'POST', body: fd });
  }
  location.reload();
}

// Show Live Stats links on every upload page URL (including /?path=…) when Debug API is up.
(function syncDebugStatsNav() {
  const navs = document.querySelectorAll('.debug-stats-nav');
  if (!navs.length) return;

  async function refresh() {
    let available = false;
    try {
      const response = await fetch('/api/health', { cache: 'no-store' });
      available = response.ok;
    } catch (_) { /* offline or debug API disabled */ }
    navs.forEach(function(el) {
      el.style.display = available ? '' : 'none';
    });
  }

  refresh();
  setInterval(refresh, 15000);
})();