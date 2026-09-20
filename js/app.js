/* College HQ — app logic. Everything reads/writes IndexedDB directly via Db
   (see js/db.js); there is no server and no localStorage. */

(function () {
  'use strict';

  const $ = (sel, root) => (root || document).querySelector(sel);
  const $all = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  function todayISO() {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    return isoFromDate(d);
  }

  function isoFromDate(d) {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  function dateFromISO(iso) {
    if (!iso) return null;
    const [y, m, d] = iso.split('-').map(Number);
    if (!y || !m || !d) return null;
    return new Date(y, m - 1, d);
  }

  function daysBetween(fromISO, toISO) {
    const a = dateFromISO(fromISO);
    const b = dateFromISO(toISO);
    if (!a || !b) return null;
    a.setHours(0, 0, 0, 0);
    b.setHours(0, 0, 0, 0);
    return Math.round((b - a) / 86400000);
  }

  function formatDateHuman(iso) {
    const d = dateFromISO(iso);
    if (!d) return 'No date';
    return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
  }

  function downloadBlob(filename, content, mime) {
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  function escapeHtml(str) {
    return String(str ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  // ---------------- CSV helpers ----------------
  function parseCsv(text) {
    const rows = [];
    let row = [];
    let field = '';
    let inQuotes = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inQuotes) {
        if (c === '"') {
          if (text[i + 1] === '"') { field += '"'; i++; }
          else inQuotes = false;
        } else field += c;
      } else if (c === '"') {
        inQuotes = true;
      } else if (c === ',') {
        row.push(field); field = '';
      } else if (c === '\n') {
        row.push(field); rows.push(row); row = []; field = '';
      } else if (c === '\r') {
        // skip, \n handles the break
      } else {
        field += c;
      }
    }
    if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }
    return rows.filter((r) => r.some((f) => f.trim() !== ''));
  }

  function csvField(value) {
    const s = String(value ?? '');
    if (/[",\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
  }

  function toCsv(headers, rows) {
    const lines = [headers.map(csvField).join(',')];
    for (const r of rows) lines.push(r.map(csvField).join(','));
    return lines.join('\n');
  }

  // Try to coerce a loose date string into YYYY-MM-DD.
  function normalizeDate(raw) {
    if (!raw) return '';
    const s = raw.trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
    const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/); // MM/DD/YYYY
    if (m) {
      const [, mo, da, yr] = m;
      return `${yr}-${mo.padStart(2, '0')}-${da.padStart(2, '0')}`;
    }
    const d = new Date(s);
    if (!isNaN(d.getTime())) return isoFromDate(d);
    return '';
  }

  // ---------------- Tabs ----------------
  function setupTabs() {
    $all('.tab-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        $all('.tab-btn').forEach((b) => b.classList.remove('active'));
        $all('.tab-pane').forEach((p) => p.classList.remove('active'));
        btn.classList.add('active');
        $(`#tab-${btn.dataset.tab}`).classList.add('active');
      });
    });
  }

  // ---------------- Overview ----------------
  async function renderOverview() {
    const [classes, assignments, settings] = await Promise.all([
      Db.getAll('classes'),
      Db.getAll('assignments'),
      Db.get('settings', 'app'),
    ]);

    $('#statClasses').textContent = classes.length;

    const open = assignments.filter((a) => !a.done);
    $('#statOpen').textContent = open.length;

    const today = todayISO();
    const dueSoon = open.filter((a) => {
      if (!a.due) return false;
      const diff = daysBetween(today, a.due);
      return diff !== null && diff >= 0 && diff <= 7;
    });
    $('#statDueSoon').textContent = dueSoon.length;

    const termStart = settings?.termStart || '';
    $('#termStartInput').value = termStart;
    if (termStart) {
      const diff = daysBetween(today, termStart);
      if (diff === null) $('#statDaysUntil').textContent = '—';
      else if (diff > 0) $('#statDaysUntil').textContent = diff;
      else if (diff === 0) $('#statDaysUntil').textContent = 'Today';
      else $('#statDaysUntil').textContent = `Started ${Math.abs(diff)}d ago`;
    } else {
      $('#statDaysUntil').textContent = '—';
    }
  }

  function setupOverview() {
    $('#termStartInput').addEventListener('change', async (e) => {
      await Db.put('settings', { key: 'app', termStart: e.target.value });
      renderOverview();
    });

    $('#downloadAllBtn').addEventListener('click', downloadAllData);
    $('#restoreInput').addEventListener('change', handleRestoreFile);
  }

  // ---------------- Classes ----------------
  async function renderClasses() {
    const classes = await Db.getAll('classes');
    const body = $('#classesBody');
    body.innerHTML = '';

    if (classes.length === 0) {
      body.innerHTML = `<tr><td colspan="5"><div class="empty-state">No classes yet. Add your first one.</div></td></tr>`;
      return;
    }

    for (const c of classes) {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><input type="text" data-field="code" value="${escapeHtml(c.code)}" placeholder="Code"></td>
        <td><input type="text" data-field="name" value="${escapeHtml(c.name)}" placeholder="Course name"></td>
        <td><input type="text" data-field="instructor" value="${escapeHtml(c.instructor)}" placeholder="Instructor"></td>
        <td><input type="text" data-field="room" value="${escapeHtml(c.room)}" placeholder="Room"></td>
        <td class="col-actions"><button class="btn-icon" title="Delete">✕</button></td>
      `;
      $all('input', tr).forEach((input) => {
        input.addEventListener('change', async () => {
          c[input.dataset.field] = input.value;
          await Db.put('classes', c);
          refreshAssignClassOptions();
        });
      });
      $('.btn-icon', tr).addEventListener('click', async () => {
        await Db.delete('classes', c.id);
        renderClasses();
        renderOverview();
        refreshAssignClassOptions();
      });
      body.appendChild(tr);
    }
  }

  function setupClasses() {
    $('#addClassBtn').addEventListener('click', async () => {
      await Db.put('classes', { code: '', name: '', instructor: '', room: '' });
      renderClasses();
      renderOverview();
      refreshAssignClassOptions();
    });
  }

  // ---------------- Timetable ----------------
  async function renderTimetable() {
    const rows = await Db.getAll('timetable');
    const body = $('#timetableBody');
    body.innerHTML = '';

    if (rows.length === 0) {
      body.innerHTML = `<tr><td colspan="7"><div class="empty-state">No time slots yet. Add one to build your weekly schedule.</div></td></tr>`;
      return;
    }

    const cols = ['time', 'mon', 'tue', 'wed', 'thu', 'fri'];
    for (const r of rows) {
      const tr = document.createElement('tr');
      tr.innerHTML = cols.map((f) =>
        `<td><input type="text" data-field="${f}" value="${escapeHtml(r[f] || '')}" placeholder="${f === 'time' ? 'e.g. 9:30–10:20' : '—'}"></td>`
      ).join('') + `<td class="col-actions"><button class="btn-icon" title="Delete">✕</button></td>`;

      $all('input', tr).forEach((input) => {
        input.addEventListener('change', async () => {
          r[input.dataset.field] = input.value;
          await Db.put('timetable', r);
        });
      });
      $('.btn-icon', tr).addEventListener('click', async () => {
        await Db.delete('timetable', r.id);
        renderTimetable();
      });
      body.appendChild(tr);
    }
  }

  function setupTimetable() {
    $('#addRowBtn').addEventListener('click', async () => {
      await Db.put('timetable', { time: '', mon: '', tue: '', wed: '', thu: '', fri: '' });
      renderTimetable();
    });
  }

  // ---------------- Assignments ----------------
  async function refreshAssignClassOptions() {
    const classes = await Db.getAll('classes');
    const sel = $('#assignClass');
    const current = sel.value;
    sel.innerHTML = '<option value="">No class</option>' +
      classes.map((c) => `<option value="${escapeHtml(c.code)}">${escapeHtml(c.code)}</option>`).join('');
    if ([...sel.options].some((o) => o.value === current)) sel.value = current;
  }

  async function renderAssignments() {
    const assignments = await Db.getAll('assignments');
    const list = $('#assignmentList');
    list.innerHTML = '';

    if (assignments.length === 0) {
      list.innerHTML = `<div class="empty-state">No assignments yet. Add one above or import a CSV.</div>`;
      return;
    }

    // sort by ISO due date (lexicographic works for YYYY-MM-DD); undated last
    assignments.sort((a, b) => {
      if (!a.due && !b.due) return 0;
      if (!a.due) return 1;
      if (!b.due) return -1;
      return a.due < b.due ? -1 : a.due > b.due ? 1 : 0;
    });

    const today = todayISO();

    for (const a of assignments) {
      const li = document.createElement('li');
      li.className = 'assignment-item';
      let flagClass = '';
      let dueClass = '';
      if (a.due && !a.done) {
        const diff = daysBetween(today, a.due);
        if (diff !== null && diff < 0) { flagClass = 'flag-overdue'; dueClass = 'due-overdue'; }
        else if (diff !== null && diff <= 3) { flagClass = 'flag-soon'; dueClass = 'due-soon'; }
      }
      if (a.done) li.classList.add('is-done');
      if (flagClass) li.classList.add(flagClass);

      li.innerHTML = `
        <input type="checkbox" ${a.done ? 'checked' : ''} title="Mark done">
        <div class="assignment-main">
          <div class="assignment-title">${escapeHtml(a.title)}</div>
          <div class="assignment-meta">
            ${a.cls ? escapeHtml(a.cls) + ' · ' : ''}<span class="${dueClass}">${a.due ? formatDateHuman(a.due) : 'No due date'}</span>
          </div>
        </div>
        <button class="btn-icon" title="Delete">✕</button>
      `;

      $('input[type="checkbox"]', li).addEventListener('change', async (e) => {
        a.done = e.target.checked;
        await Db.put('assignments', a);
        renderAssignments();
        renderOverview();
      });
      $('.btn-icon', li).addEventListener('click', async () => {
        await Db.delete('assignments', a.id);
        renderAssignments();
        renderOverview();
      });
      list.appendChild(li);
    }
  }

  function setupAssignments() {
    $('#addAssignmentForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const title = $('#assignTitle').value.trim();
      if (!title) return;
      const cls = $('#assignClass').value;
      const due = $('#assignDue').value;
      await Db.put('assignments', { title, cls, due, done: false });
      $('#assignTitle').value = '';
      $('#assignDue').value = '';
      renderAssignments();
      renderOverview();
    });

    $('#importCsvInput').addEventListener('change', async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      const text = await file.text();
      const rows = parseCsv(text);
      if (rows.length === 0) { e.target.value = ''; return; }

      let dataRows = rows;
      const header = rows[0].map((h) => h.trim().toLowerCase());
      const looksLikeHeader = header.includes('title') || header.includes('class') || header.includes('due') || header.includes('due date');
      if (looksLikeHeader) dataRows = rows.slice(1);

      let imported = 0;
      for (const r of dataRows) {
        const title = (r[0] || '').trim();
        if (!title) continue;
        const cls = (r[1] || '').trim();
        const due = normalizeDate(r[2] || '');
        await Db.put('assignments', { title, cls, due, done: false });
        imported++;
      }
      e.target.value = '';
      renderAssignments();
      renderOverview();
      setStatus(`Imported ${imported} assignment${imported === 1 ? '' : 's'} from CSV.`);
    });

    $('#exportCsvBtn').addEventListener('click', async () => {
      const assignments = await Db.getAll('assignments');
      const csv = toCsv(['title', 'class', 'due date', 'done'],
        assignments.map((a) => [a.title, a.cls || '', a.due || '', a.done ? 'yes' : 'no']));
      downloadBlob(`college-hq-assignments-${todayISO()}.csv`, csv, 'text/csv');
    });

    $('#exportMdBtn').addEventListener('click', async () => {
      const assignments = await Db.getAll('assignments');
      assignments.sort((a, b) => (a.due || '9999') < (b.due || '9999') ? -1 : 1);
      let md = `# Assignments\n\n`;
      for (const a of assignments) {
        md += `- [${a.done ? 'x' : ' '}] **${a.title}**${a.cls ? ` (${a.cls})` : ''}${a.due ? ` — due ${formatDateHuman(a.due)}` : ''}\n`;
      }
      downloadBlob(`college-hq-assignments-${todayISO()}.md`, md, 'text/markdown');
    });
  }

  // ---------------- Planner ----------------
  async function renderPlanner() {
    const grid = $('#plannerGrid');
    grid.innerHTML = '';
    const days = await Promise.all(window.DAYS.map((d) => Db.get('planner', d)));

    days.forEach((dayRec, idx) => {
      const day = window.DAYS[idx];
      const items = dayRec?.items || [];
      const col = document.createElement('div');
      col.className = 'planner-day';
      col.innerHTML = `
        <h3>${day}</h3>
        <ul class="planner-items"></ul>
        <form class="planner-add">
          <input type="text" placeholder="Add task…">
          <button type="submit" class="btn btn-outline">+</button>
        </form>
      `;
      const ul = $('.planner-items', col);
      items.forEach((item, i) => {
        const li = document.createElement('li');
        li.className = 'planner-item' + (item.done ? ' done' : '');
        li.innerHTML = `<input type="checkbox" ${item.done ? 'checked' : ''}><span>${escapeHtml(item.text)}</span><button class="btn-icon" title="Delete">✕</button>`;
        $('input[type="checkbox"]', li).addEventListener('change', async (e) => {
          items[i].done = e.target.checked;
          await Db.put('planner', { day, items });
          renderPlanner();
        });
        $('.btn-icon', li).addEventListener('click', async () => {
          items.splice(i, 1);
          await Db.put('planner', { day, items });
          renderPlanner();
        });
        ul.appendChild(li);
      });

      $('.planner-add', col).addEventListener('submit', async (e) => {
        e.preventDefault();
        const input = e.target.querySelector('input');
        const text = input.value.trim();
        if (!text) return;
        items.push({ text, done: false });
        await Db.put('planner', { day, items });
        renderPlanner();
      });

      grid.appendChild(col);
    });
  }

  // ---------------- Notes ----------------
  async function renderNotes() {
    const notes = await Db.getAll('notes');
    const grid = $('#notesGrid');
    grid.innerHTML = '';

    if (notes.length === 0) {
      grid.innerHTML = `<div class="empty-state">No notes yet. Create one to get started.</div>`;
      return;
    }

    for (const n of notes) {
      const card = document.createElement('div');
      card.className = 'note-card';
      card.innerHTML = `
        <input type="text" value="${escapeHtml(n.title)}" placeholder="Note title">
        <textarea placeholder="Write something…">${escapeHtml(n.body)}</textarea>
        <div class="note-card-foot"><button class="btn-icon" title="Delete">✕</button></div>
      `;
      const titleInput = $('input', card);
      const bodyInput = $('textarea', card);
      let saveTimer = null;
      const save = async () => {
        n.title = titleInput.value;
        n.body = bodyInput.value;
        await Db.put('notes', n);
      };
      const debouncedSave = () => {
        clearTimeout(saveTimer);
        saveTimer = setTimeout(save, 400);
      };
      titleInput.addEventListener('input', debouncedSave);
      bodyInput.addEventListener('input', debouncedSave);
      titleInput.addEventListener('blur', save);
      bodyInput.addEventListener('blur', save);

      $('.btn-icon', card).addEventListener('click', async () => {
        await Db.delete('notes', n.id);
        renderNotes();
      });
      grid.appendChild(card);
    }
  }

  function setupNotes() {
    $('#addNoteBtn').addEventListener('click', async () => {
      await Db.put('notes', { title: '', body: '' });
      renderNotes();
    });

    $('#exportNotesBtn').addEventListener('click', async () => {
      const notes = await Db.getAll('notes');
      let md = '';
      for (const n of notes) {
        md += `## ${n.title || 'Untitled'}\n\n${n.body || ''}\n\n---\n\n`;
      }
      downloadBlob(`college-hq-notes-${todayISO()}.md`, md, 'text/markdown');
    });
  }

  // ---------------- Backup / restore ----------------
  async function downloadAllData() {
    const [classes, timetable, assignments, notes, settings] = await Promise.all([
      Db.getAll('classes'), Db.getAll('timetable'), Db.getAll('assignments'),
      Db.getAll('notes'), Db.get('settings', 'app'),
    ]);
    const planner = {};
    for (const day of window.DAYS) {
      const rec = await Db.get('planner', day);
      planner[day] = rec?.items || [];
    }
    const backup = {
      app: 'college-hq', version: 1, exportedAt: new Date().toISOString(),
      classes, timetable, assignments, planner, notes, settings: settings || { key: 'app', termStart: '' },
    };
    downloadBlob(`college-hq-backup-${todayISO()}.json`, JSON.stringify(backup, null, 2), 'application/json');
  }

  async function handleRestoreFile(e) {
    const file = e.target.files[0];
    if (!file) return;
    try {
      const text = await file.text();
      const data = JSON.parse(text);
      if (!data || typeof data !== 'object') throw new Error('Invalid file');

      const ok = confirm('Restoring will replace all current data in College HQ with the contents of this backup. Continue?');
      if (!ok) { e.target.value = ''; return; }

      if (Array.isArray(data.classes)) await Db.replaceStore('classes', data.classes.map(stripId));
      if (Array.isArray(data.timetable)) await Db.replaceStore('timetable', data.timetable.map(stripId));
      if (Array.isArray(data.assignments)) await Db.replaceStore('assignments', data.assignments.map(stripId));
      if (Array.isArray(data.notes)) await Db.replaceStore('notes', data.notes.map(stripId));

      if (data.planner && typeof data.planner === 'object') {
        for (const day of window.DAYS) {
          await Db.put('planner', { day, items: Array.isArray(data.planner[day]) ? data.planner[day] : [] });
        }
      }
      if (data.settings) {
        await Db.put('settings', { key: 'app', termStart: data.settings.termStart || '' });
      }

      await renderAll();
      setStatus('Backup restored successfully.');
    } catch (err) {
      alert('Could not read that file as a College HQ backup: ' + err.message);
    } finally {
      e.target.value = '';
    }
  }

  function stripId(obj) {
    const { id, ...rest } = obj;
    return rest;
  }

  function setStatus(msg) {
    const el = $('#dbStatus');
    el.textContent = msg;
    clearTimeout(setStatus._t);
    setStatus._t = setTimeout(() => { el.textContent = 'All data saved on this device.'; }, 3500);
  }

  // ---------------- Install prompt ----------------
  function setupInstallPrompt() {
    let deferredPrompt = null;
    const btn = $('#installBtn');
    window.addEventListener('beforeinstallprompt', (e) => {
      e.preventDefault();
      deferredPrompt = e;
      btn.hidden = false;
    });
    btn.addEventListener('click', async () => {
      if (!deferredPrompt) return;
      deferredPrompt.prompt();
      await deferredPrompt.userChoice;
      deferredPrompt = null;
      btn.hidden = true;
    });
    window.addEventListener('appinstalled', () => { btn.hidden = true; });
  }

  // ---------------- Service worker ----------------
  function setupServiceWorker() {
    if ('serviceWorker' in navigator && (location.protocol === 'http:' || location.protocol === 'https:')) {
      navigator.serviceWorker.register('sw.js').catch(() => {});
    }
  }

  // ---------------- Boot ----------------
  async function renderAll() {
    await Promise.all([
      renderOverview(),
      renderClasses(),
      renderTimetable(),
      renderAssignments(),
      renderPlanner(),
      renderNotes(),
    ]);
    await refreshAssignClassOptions();
  }

  async function init() {
    setupTabs();
    setupOverview();
    setupClasses();
    setupTimetable();
    setupAssignments();
    setupNotes();
    setupInstallPrompt();
    setupServiceWorker();

    await Db.seedIfEmpty();
    await renderAll();
    setStatus('All data saved on this device.');
  }

  document.addEventListener('DOMContentLoaded', init);
})();
