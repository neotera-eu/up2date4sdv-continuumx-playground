import "./globals.css";

export const metadata = {
  title: "Firmware catalog · ContinuumX",
  description: "Upload and publish firmware binaries for OTA device updates",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
