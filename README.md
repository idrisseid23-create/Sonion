# College HQ

A installable, offline-first dashboard for your first semester at Douglas
College (Associate of Science). Pure client-side HTML/CSS/JS — no backend,
no build step. All data lives in your browser's IndexedDB, on your device
only.

## Features

- **Overview** — live stats (classes, open assignments, due-within-7-days,
  days until term start).
- **Classes** — pre-filled with MATH 1110, PHYS 1107, CHEM 1108, CMNS 1115,
  CMPT 1105 (edit the course names/instructor/room to match your actual
  registration — the pre-filled titles are placeholders, confirm the exact
  titles from your Douglas College enrollment).
- **Timetable** — a Mon–Fri grid you build out yourself.
- **Assignments** — sorted by due date, overdue flagged red, due-within-3-days
  flagged gold. Import from CSV, export to CSV or Markdown.
- **Planner** — a Sun–Sat weekly task board.
- **Notes** — free-form notes, exportable to Markdown.
- **Backup** — "Download all data" bundles everything into one JSON file you
  can re-import later to restore the whole app.

## How to open and install it

A PWA's "Install" prompt and its offline service worker **only work when the
page is loaded over `http://` or `https://`** — not from a `file://` path.
So the one-time setup is to serve the folder locally, then install it as an
app. After that, it runs standalone and fully offline; you don't need the
server running again.

### 1. Serve the folder once (pick any one option)

```bash
# Option A — Python (usually preinstalled)
cd college-hq
python3 -m http.server 8080

# Option B — Node, if you have it
npx serve college-hq -p 8080
```

Then open **http://localhost:8080** in Chrome, Edge, or another
Chromium-based browser (Safari on iOS/macOS works for the "Add to Home
Screen" flow too, see below).

### 2. Install it

- **Desktop Chrome/Edge:** click the install icon (⊕ / a small monitor icon)
  in the address bar, or use the in-app **"Install App"** button that
  appears in the header. This gives you a real desktop app window and an
  icon in your Start Menu / Applications / Dock.
- **Android Chrome:** open the site, tap the **⋮** menu → **"Install app"**
  (or the in-app **"Install App"** button). It's added to your home screen
  and launches full-screen.
- **iOS Safari:** open the site, tap the **Share** icon → **"Add to Home
  Screen."** iOS doesn't support the `beforeinstallprompt` button, so this
  manual step is required there.

Once installed, the app opens in its own window (no browser chrome), and the
service worker has already cached every file — you can turn off Wi-Fi and
it still works, including all your data.

### 3. Everyday use

You generally don't need the local server again — the installed app is
self-contained. If you ever want to open it in a plain browser tab instead
of the installed app, you *can* re-run the server and visit the URL, or you
can double-click `index.html` directly, but note: opening via `file://`
disables the service worker and install prompt (IndexedDB storage, tabs, and
all data features still work fine that way — it's only "install as an app"
and the offline cache that need the `http(s)://` origin).

## Data & backups

- Everything writes to IndexedDB immediately as you type/toggle — there's no
  "Save" button to forget.
- Use **Overview → Download all data (JSON)** regularly and keep the file
  somewhere safe (cloud drive, USB, email to yourself). If you ever clear
  your browser data, reinstall the app, or switch devices, use **Overview →
  Restore from backup** and pick that JSON file to get everything back.
- Assignments can also be exported/imported as CSV (`title, class, due date`
  columns) and exported as Markdown; Notes export as Markdown.

## File structure

```
index.html          Single-page app shell, all six tabs
css/styles.css       Dark navy/gold theme
js/db.js             IndexedDB wrapper + first-run seeding
js/app.js            All UI logic, CSV/Markdown/JSON import-export
manifest.json         PWA manifest (name, icons, theme colors, standalone display)
sw.js                Service worker — caches the app shell for offline use
icons/               App icons (192/512, incl. maskable, apple-touch-icon, favicon)
```
