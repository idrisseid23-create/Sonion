/* IndexedDB wrapper for College HQ. No server, no localStorage — everything
   lives in the browser's IndexedDB so it survives offline and across
   launches of the installed PWA. */

const DB_NAME = 'college-hq';
const DB_VERSION = 1;

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const DEFAULT_CLASSES = [
  { code: 'MATH 1110', name: 'Calculus (confirm exact title)', instructor: '', room: '' },
  { code: 'PHYS 1107', name: 'Physics (confirm exact title)', instructor: '', room: '' },
  { code: 'CHEM 1108', name: 'Chemistry (confirm exact title)', instructor: '', room: '' },
  { code: 'CMNS 1115', name: 'Communications (confirm exact title)', instructor: '', room: '' },
  { code: 'CMPT 1105', name: 'Computing (confirm exact title)', instructor: '', room: '' },
];

let dbPromise = null;

function openDb() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = (e) => {
      const db = req.result;
      if (!db.objectStoreNames.contains('classes')) {
        db.createObjectStore('classes', { keyPath: 'id', autoIncrement: true });
      }
      if (!db.objectStoreNames.contains('timetable')) {
        db.createObjectStore('timetable', { keyPath: 'id', autoIncrement: true });
      }
      if (!db.objectStoreNames.contains('assignments')) {
        db.createObjectStore('assignments', { keyPath: 'id', autoIncrement: true });
      }
      if (!db.objectStoreNames.contains('planner')) {
        db.createObjectStore('planner', { keyPath: 'day' });
      }
      if (!db.objectStoreNames.contains('notes')) {
        db.createObjectStore('notes', { keyPath: 'id', autoIncrement: true });
      }
      if (!db.objectStoreNames.contains('settings')) {
        db.createObjectStore('settings', { keyPath: 'key' });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

function tx(storeNames, mode) {
  return openDb().then((db) => db.transaction(storeNames, mode));
}

function reqToPromise(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

const Db = {
  async getAll(store) {
    const t = await tx(store, 'readonly');
    return reqToPromise(t.objectStore(store).getAll());
  },

  async get(store, key) {
    const t = await tx(store, 'readonly');
    return reqToPromise(t.objectStore(store).get(key));
  },

  async put(store, value) {
    const t = await tx(store, 'readwrite');
    const result = await reqToPromise(t.objectStore(store).put(value));
    return result;
  },

  async delete(store, key) {
    const t = await tx(store, 'readwrite');
    return reqToPromise(t.objectStore(store).delete(key));
  },

  async clear(store) {
    const t = await tx(store, 'readwrite');
    return reqToPromise(t.objectStore(store).clear());
  },

  async putAll(store, values) {
    const t = await tx(store, 'readwrite');
    const os = t.objectStore(store);
    for (const v of values) os.put(v);
    return new Promise((resolve, reject) => {
      t.oncomplete = () => resolve();
      t.onerror = () => reject(t.error);
    });
  },

  /** Replace an entire store's contents atomically. */
  async replaceStore(store, values) {
    const t = await tx(store, 'readwrite');
    const os = t.objectStore(store);
    os.clear();
    for (const v of values) {
      // Strip autoIncrement ids so restored records get fresh keys, unless
      // the store uses a fixed keyPath (planner/settings) where the id IS the key.
      os.put(v);
    }
    return new Promise((resolve, reject) => {
      t.oncomplete = () => resolve();
      t.onerror = () => reject(t.error);
    });
  },

  async seedIfEmpty() {
    const classes = await this.getAll('classes');
    if (classes.length === 0) {
      for (const c of DEFAULT_CLASSES) await this.put('classes', c);
    }
    const planner = await this.getAll('planner');
    if (planner.length === 0) {
      for (const day of DAYS) await this.put('planner', { day, items: [] });
    }
    const settings = await this.get('settings', 'app');
    if (!settings) {
      await this.put('settings', { key: 'app', termStart: '2027-01-04' });
    }
  },
};

window.Db = Db;
window.DAYS = DAYS;
