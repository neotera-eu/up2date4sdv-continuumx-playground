import { createReadStream } from "fs";
import { stat } from "fs/promises";
import { Readable } from "stream";
import { NextResponse } from "next/server";
import { findFirmware } from "../../../lib/store";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request) {
  try {
    const { searchParams } = new URL(request.url);
    const name = searchParams.get("name");
    const version = searchParams.get("version");

    if (!name || !version) {
      return NextResponse.json(
        {
          ok: false,
          error: "query args required: name, version",
          example: "/api/download?name=thermal-ecu&version=1.2.0",
        },
        { status: 400 },
      );
    }

    const found = await findFirmware(name, version);
    if (!found) {
      return NextResponse.json(
        { ok: false, error: `firmware not found: ${name}@${version}` },
        { status: 404 },
      );
    }

    const st = await stat(found.filePath);
    const stream = createReadStream(found.filePath);
    const webStream = Readable.toWeb(stream);

    const filename = found.item.originalName || found.item.storedAs;
    return new NextResponse(webStream, {
      status: 200,
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(st.size),
        "Content-Disposition": `attachment; filename="${filename.replace(/"/g, "")}"`,
        "X-Firmware-Name": found.item.name,
        "X-Firmware-Version": found.item.version,
        "X-Firmware-Sha256": found.item.sha256,
        "Cache-Control": "no-store",
      },
    });
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err?.message || String(err) },
      { status: 500 },
    );
  }
}
