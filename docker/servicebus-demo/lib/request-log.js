const MAX = 50;
const entries = [];

export function pushRequest(entry) {
  entries.unshift({
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    at: new Date().toISOString(),
    ...entry,
  });
  if (entries.length > MAX) entries.length = MAX;
  return entries[0];
}

export function listRequests() {
  return entries;
}

export function clearRequests() {
  entries.length = 0;
}
