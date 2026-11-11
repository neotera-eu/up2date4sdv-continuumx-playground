"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

function formatBytes(n) {
  if (!Number.isFinite(n)) return "-";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  return `${(n / (1024 * 1024)).toFixed(2)} MiB`;
}

function absoluteUrl(path) {
  if (typeof window === "undefined") return path;
  return `${window.location.origin}${path}`;
}

export default function Page() {
  const [items, setItems] = useState([]);
  const [status, setStatus] = useState("");
  const [statusKind, setStatusKind] = useState("");
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({
    name: "",
    version: "",
    deviceModel: "automotive-thermal-ecu",
    description: "",
    file: null,
  });

  const refresh = useCallback(async () => {
    const res = await fetch("/api/firmwares", { cache: "no-store" });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || `list failed (${res.status})`);
    }
    setItems(data.items || []);
  }, []);

  useEffect(() => {
    refresh().catch((err) => {
      setStatusKind("err");
      setStatus(err.message);
    });
  }, [refresh]);

  const countLabel = useMemo(() => {
    const n = items.length;
    return n === 1 ? "1 firmware" : `${n} firmwares`;
  }, [items.length]);

  function onField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  async function onUpload(e) {
    e.preventDefault();
    if (!form.file) {
      setStatusKind("err");
      setStatus("choose a firmware binary");
      return;
    }
    setBusy(true);
    setStatusKind("");
    setStatus("uploading...");
    try {
      const body = new FormData();
      body.set("name", form.name);
      body.set("version", form.version);
      body.set("deviceModel", form.deviceModel);
      body.set("description", form.description);
      body.set("file", form.file);

      const res = await fetch("/api/firmwares", { method: "POST", body });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        throw new Error(data.error || `upload failed (${res.status})`);
      }
      setOpen(false);
      setForm({
        name: "",
        version: "",
        deviceModel: "automotive-thermal-ecu",
        description: "",
        file: null,
      });
      await refresh();
      setStatusKind("ok");
      setStatus(`uploaded ${data.item.name}@${data.item.version}`);
    } catch (err) {
      setStatusKind("err");
      setStatus(err.message);
    } finally {
      setBusy(false);
    }
  }

  async function onDelete(item) {
    if (!window.confirm(`Delete ${item.name}@${item.version}?`)) return;
    setBusy(true);
    try {
      const q = new URLSearchParams({
        name: item.name,
        version: item.version,
      });
      const res = await fetch(`/api/firmwares?${q}`, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        throw new Error(data.error || `delete failed (${res.status})`);
      }
      await refresh();
      setStatusKind("ok");
      setStatus(`deleted ${item.name}@${item.version}`);
    } catch (err) {
      setStatusKind("err");
      setStatus(err.message);
    } finally {
      setBusy(false);
    }
  }

  async function copyUrl(path) {
    const url = absoluteUrl(path);
    try {
      await navigator.clipboard.writeText(url);
      setStatusKind("ok");
      setStatus(`copied ${url}`);
    } catch {
      setStatusKind("err");
      setStatus("copy failed — select the URL manually");
    }
  }

  return (
    <main>
      <p className="brand">ContinuumX · OTA</p>
      <h1>Firmware catalog</h1>
      <p className="lede">
        Upload firmware binaries and publish download URLs for edge OTA.
        Locate a build with query args{" "}
        <code>name</code> and <code>version</code>.
      </p>

      <div className="toolbar">
        <div className="hint">{countLabel} stored on this host</div>
        <button
          type="button"
          className="primary"
          disabled={busy}
          onClick={() => setOpen(true)}
        >
          Upload firmware
        </button>
      </div>

      <p className={`status ${statusKind}`}>{status}</p>

      <div className="table-wrap">
        {items.length === 0 ? (
          <div className="empty">
            No firmware yet. Upload a binary to publish its download URL.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Name / version</th>
                <th className="hide-sm">Meta</th>
                <th>Download URL</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {items.map((item) => (
                <tr key={item.id}>
                  <td>
                    <div className="name">
                      {item.name}
                      <span style={{ color: "var(--muted)", fontWeight: 500 }}>
                        {" "}
                        @ {item.version}
                      </span>
                    </div>
                    {item.description ? (
                      <div className="meta">{item.description}</div>
                    ) : null}
                  </td>
                  <td className="hide-sm">
                    <div className="meta">
                      {item.deviceModel || "—"}
                      <br />
                      {formatBytes(item.size)} · sha256{" "}
                      <code>{item.sha256.slice(0, 12)}…</code>
                      <br />
                      {new Date(item.uploadedAt).toLocaleString()}
                    </div>
                  </td>
                  <td className="url">
                    <a href={item.downloadUrl}>{absoluteUrl(item.downloadUrl)}</a>
                  </td>
                  <td>
                    <div className="row-actions">
                      <button
                        type="button"
                        className="ghost"
                        disabled={busy}
                        onClick={() => copyUrl(item.downloadUrl)}
                      >
                        Copy URL
                      </button>
                      <a className="btn ghost" href={item.downloadUrl}>
                        Download
                      </a>
                      <button
                        type="button"
                        className="danger"
                        disabled={busy}
                        onClick={() => onDelete(item)}
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {open ? (
        <div
          className="backdrop"
          role="presentation"
          onClick={(e) => {
            if (e.target === e.currentTarget && !busy) setOpen(false);
          }}
        >
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="upload-title"
          >
            <h2 id="upload-title">Upload firmware</h2>
            <p>
              Metadata is stored with the binary. The download URL uses{" "}
              <code>?name=&amp;version=</code>.
            </p>
            <form className="form" onSubmit={onUpload}>
              <label>
                Name
                <input
                  required
                  value={form.name}
                  placeholder="thermal-ecu"
                  onChange={(e) => onField("name", e.target.value)}
                />
              </label>
              <label>
                Version
                <input
                  required
                  value={form.version}
                  placeholder="1.2.0"
                  onChange={(e) => onField("version", e.target.value)}
                />
              </label>
              <label>
                Device model
                <input
                  value={form.deviceModel}
                  placeholder="automotive-thermal-ecu"
                  onChange={(e) => onField("deviceModel", e.target.value)}
                />
              </label>
              <label>
                Description
                <textarea
                  value={form.description}
                  placeholder="Optional notes for this build"
                  onChange={(e) => onField("description", e.target.value)}
                />
              </label>
              <label>
                Binary file
                <input
                  required
                  type="file"
                  onChange={(e) =>
                    onField("file", e.target.files?.[0] || null)
                  }
                />
              </label>
              <div className="modal-actions">
                <button
                  type="button"
                  className="ghost"
                  disabled={busy}
                  onClick={() => setOpen(false)}
                >
                  Cancel
                </button>
                <button type="submit" className="primary" disabled={busy}>
                  {busy ? "Uploading…" : "Publish"}
                </button>
              </div>
            </form>
          </div>
        </div>
      ) : null}
    </main>
  );
}
