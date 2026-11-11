import { NextResponse } from "next/server";
import { deleteFirmware, listFirmwares, saveFirmware } from "../../../lib/store";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  const items = await listFirmwares();
  return NextResponse.json({ ok: true, items });
}

export async function POST(request) {
  try {
    const form = await request.formData();
    const file = form.get("file");
    if (!file || typeof file === "string") {
      return NextResponse.json(
        { ok: false, error: "multipart field 'file' is required" },
        { status: 400 },
      );
    }

    const buffer = Buffer.from(await file.arrayBuffer());
    const item = await saveFirmware({
      name: form.get("name"),
      version: form.get("version"),
      description: form.get("description") || "",
      deviceModel: form.get("deviceModel") || "",
      originalName: file.name || "firmware.bin",
      buffer,
    });

    return NextResponse.json({ ok: true, item }, { status: 201 });
  } catch (err) {
    const message = err?.message || String(err);
    const status = /already exists|required|too long|too large|empty/i.test(
      message,
    )
      ? 400
      : 500;
    return NextResponse.json({ ok: false, error: message }, { status });
  }
}

export async function DELETE(request) {
  try {
    const { searchParams } = new URL(request.url);
    const name = searchParams.get("name");
    const version = searchParams.get("version");
    const removed = await deleteFirmware(name, version);
    if (!removed) {
      return NextResponse.json(
        { ok: false, error: "firmware not found" },
        { status: 404 },
      );
    }
    return NextResponse.json({ ok: true });
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err?.message || String(err) },
      { status: 400 },
    );
  }
}
