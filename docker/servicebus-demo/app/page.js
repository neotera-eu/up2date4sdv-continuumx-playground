"use client";

import { useCallback, useEffect, useState } from "react";

export default function Page() {
  const [requests, setRequests] = useState([]);
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);
  const [lastReply, setLastReply] = useState(null);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch("/api/requests", { cache: "no-store" });
      const data = await res.json();
      setRequests(data.requests || []);
    } catch (err) {
      setStatus(`refresh failed: ${err.message}`);
    }
  }, []);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 1500);
    return () => clearInterval(id);
  }, [refresh]);

  async function run(label, fn) {
    setBusy(true);
    setStatus(`${label}...`);
    setLastReply(null);
    try {
      await fn();
      await refresh();
    } catch (err) {
      setStatus(`error: ${err.message}`);
    } finally {
      setBusy(false);
    }
  }

  function sendViaServiceBus() {
    return run("ServiceBus", async () => {
      const res = await fetch("/api/trigger", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ msg: "ping from UI via ServiceBus" }),
      });
      const data = await res.json();
      setLastReply(data);
      setStatus(
        data.ok
          ? "ServiceBus OK - cloud -> edge HTTP"
          : `ServiceBus failed: ${data.error || data.status || res.status}`,
      );
    });
  }

  function pingLocal() {
    return run("local echo", async () => {
      const res = await fetch("/api/echo", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ msg: "direct local call (no ServiceBus)" }),
      });
      const data = await res.json();
      setLastReply(data);
      setStatus("local /api/echo OK - bypasses ServiceBus");
    });
  }

  function checkHealth() {
    return run("health", async () => {
      const res = await fetch("/api/health", { cache: "no-store" });
      const data = await res.json();
      setLastReply(data);
      setStatus(data.ok ? "edge app healthy" : "health check failed");
    });
  }

  async function clearLog() {
    await fetch("/api/requests", { method: "DELETE" });
    setLastReply(null);
    setStatus("log cleared");
    await refresh();
  }

  return (
    <main>
      <header>
        <h1>ServiceBus demo</h1>
        <p className="tagline">Cloud HTTP -&gt; edge app</p>
      </header>

      <div className="flow" aria-hidden="true">
        <span className="chip">UI</span>
        <span className="arrow">-&gt;</span>
        <span className="chip">Router</span>
        <span className="arrow">-&gt;</span>
        <span className="chip accent">ServiceBus</span>
        <span className="arrow">-&gt;</span>
        <span className="chip accent">/api/echo</span>
      </div>

      <div className="controls">
        <button className="primary" disabled={busy} onClick={sendViaServiceBus}>
          Send via ServiceBus
        </button>
        <button disabled={busy} onClick={pingLocal}>
          Ping local API
        </button>
        <button disabled={busy} onClick={checkHealth}>
          Health
        </button>
        <button disabled={busy} onClick={clearLog}>
          Clear log
        </button>
      </div>

      <p
        className={`status ${
          status.includes("OK") || status.includes("healthy")
            ? "ok"
            : status.includes("fail") || status.includes("error")
              ? "err"
              : ""
        }`}
      >
        {status || "Ready"}
      </p>

      <div className="grid">
        <section className="panel">
          <h2>Last reply</h2>
          {lastReply ? (
            <pre>{JSON.stringify(lastReply, null, 2)}</pre>
          ) : (
            <p className="empty">No reply yet</p>
          )}
        </section>

        <section className="panel">
          <h2>Edge hits ({requests.length})</h2>
          {requests.length === 0 ? (
            <p className="empty">Nothing received yet</p>
          ) : (
            <ul className="log">
              {requests.map((r) => (
                <li key={r.id}>
                  <div className="meta">
                    {new Date(r.at).toLocaleTimeString()} · {r.method} {r.path}
                  </div>
                  <pre>{JSON.stringify(r.body, null, 2)}</pre>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}
