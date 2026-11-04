import { NextResponse } from "next/server";

// CloudCore Router URL used by the "Send via ServiceBus" button.
// You may override with env SERVICEBUS_ROUTER_URL.
const ROUTER =
  process.env.SERVICEBUS_ROUTER_URL ||
  "http://cloud:9443/u2deb-edge/default/demo";

export async function POST(req) {
  let payload = { msg: "hello via ServiceBus" };
  try {
    const body = await req.json();
    if (body && typeof body === "object") payload = { ...payload, ...body };
  } catch {
    /* keep default payload */
  }
  payload.at = new Date().toISOString();

  try {
    const res = await fetch(ROUTER, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      cache: "no-store",
    });
    const text = await res.text();
    let data = text;
    try {
      data = JSON.parse(text);
    } catch {
      /* leave as text */
    }
    return NextResponse.json(
      { ok: res.ok, status: res.status, via: "CloudCore Router -> ServiceBus", data },
      { status: res.ok ? 200 : 502 },
    );
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err.message, router: ROUTER },
      { status: 502 },
    );
  }
}
