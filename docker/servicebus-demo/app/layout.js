import "./globals.css";

export const metadata = {
  title: "ServiceBus demo · ContinuumX",
  description: "See how KubeEdge ServiceBus reaches an HTTP app on the edge",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
