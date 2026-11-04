import { NextResponse } from "next/server";
import { pushRequest } from "../../../lib/request-log";

async function handle(req) {
  let body = null;
  const text = await req.text();
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }

  const entry = pushRequest({
    method: req.method,
    path: "/api/echo",
    body,
    note: "reached via EdgeCore ServiceBus -> 127.0.0.1:3000",
  });

  return NextResponse.json({
    ok: true,
    echoed: body,
    edge: {
      hostname: process.env.HOSTNAME || "servicebus-demo",
      receivedAt: entry.at,
    },
    meaning:
      "Cloud called CloudCore Router; EdgeHub delivered the message; ServiceBus did this HTTP call on the edge.",
  });
}

export const GET = handle;
export const POST = handle;
export const PUT = handle;
export const DELETE = handle;
