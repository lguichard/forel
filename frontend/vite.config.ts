import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Wails serves the dev frontend on this port (see Taskfile VITE_PORT).
  server: {
    port: 9245,
    strictPort: true,
  },
});
