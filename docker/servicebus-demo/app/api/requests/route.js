import { NextResponse } from "next/server";
import { clearRequests, listRequests } from "../../../lib/request-log";

export async function GET() {
  return NextResponse.json({ requests: listRequests() });
}

export async function DELETE() {
  clearRequests();
  return NextResponse.json({ cleared: true });
}
