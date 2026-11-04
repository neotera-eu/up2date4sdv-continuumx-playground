import { NextResponse } from "next/server";
import { pushRequest } from "../../../lib/request-log";

export async function GET() {
  pushRequest({
    method: "GET",
    path: "/api/health",
    body: null,
    note: "health probe",
  });
  return NextResponse.json({
    ok: true,
    service: "servicebus-demo",
    role: "edge HTTP target for KubeEdge ServiceBus",
    time: new Date().toISOString(),
  });
}
