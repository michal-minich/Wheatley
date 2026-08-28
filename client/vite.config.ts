import { defineConfig } from "vite";

const apiHost = process.env.WHEATLEY_API_HOST ?? "127.0.0.1";
const apiPort = process.env.WHEATLEY_API_PORT ?? "8765";
const apiProxyTarget = process.env.VITE_WHEATLEY_API_PROXY_TARGET ?? `http://${apiHost}:${apiPort}`;
const nativeBuild = process.env.WHEATLEY_BUILD_TARGET === "native";
const nativeDevHost = process.env.TAURI_DEV_HOST;

export default defineConfig({
    build: {
        outDir: nativeBuild ? "dist/tauri" : "dist",
    },
    server: {
        host: nativeBuild ? (nativeDevHost ?? "127.0.0.1") : "127.0.0.1",
        port: nativeBuild ? 1420 : 5173,
        strictPort: nativeBuild,
        hmr: nativeDevHost === undefined ? undefined : {
            protocol: "ws",
            host: nativeDevHost,
            port: 1421,
        },
        proxy: nativeBuild ? undefined : {
            "/api": {
                target: apiProxyTarget,
                ws: true,
            },
            "^/chat/[^/]+/\\d{4}-\\d{2}-\\d{2}-[^/]+/(screenshot|generated-image|search-image)/\\d+$": {
                target: apiProxyTarget,
            },
            "^/chat/[^/]+/\\d{4}-\\d{2}-\\d{2}-[^/]+/screenshot/\\d+/model$": {
                target: apiProxyTarget,
            },
            "^/chat/[^/]+/\\d{4}-\\d{2}-\\d{2}-[^/]+/image/\\d+/[^/]+$": {
                target: apiProxyTarget,
            },
        },
        watch: nativeBuild ? { ignored: ["**/src-tauri/**"] } : undefined,
    },
});
