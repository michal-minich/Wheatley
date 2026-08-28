import { BrowserAudioRuntime } from "../audio/BrowserAudioRuntime";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";

type ScreenScope = "active_window" | "active_display";

interface CaptureTrackSettings extends MediaTrackSettings {
    readonly displaySurface?: "browser" | "window" | "monitor";
    readonly screenPixelRatio?: number;
    readonly resizeMode?: string;
}

interface ClientToolRequest {
    readonly request_id: string;
    readonly capability: string;
    readonly arguments: {
        readonly scope: ScreenScope;
        readonly model_max_long_edge_px: number;
        readonly model_pixels_per_logical_pixel: number;
    };
}

export class BrowserScreenCapture {
    readonly #endpoint: WheatleyEndpoint;
    readonly #audio: BrowserAudioRuntime;
    readonly #profileId: () => string;
    readonly #changed: (active: boolean) => void;
    readonly #handled = new Set<string>();
    #stream: MediaStream | undefined;
    #video: HTMLVideoElement | undefined;
    #scope: ScreenScope | undefined;
    #uiScale = 1;
    #pollTimer: number | undefined;
    #advertiseTimer: number | undefined;

    constructor(
        endpoint: WheatleyEndpoint,
        audio: BrowserAudioRuntime,
        profileId: () => string,
        changed: (active: boolean) => void,
    ) {
        this.#endpoint = endpoint;
        this.#audio = audio;
        this.#profileId = profileId;
        this.#changed = changed;
    }

    get active(): boolean { return this.#stream !== undefined; }

    async toggle(): Promise<void> {
        if (this.active) {
            await this.stop();
            return;
        }
        await this.start();
    }

    async start(): Promise<void> {
        const mediaDevices = navigator.mediaDevices as MediaDevices & {
            readonly getDisplayMedia?: MediaDevices["getDisplayMedia"];
        };
        if (typeof mediaDevices.getDisplayMedia !== "function")
            throw new Error("Screen sharing is unavailable in this browser.");
        const stream = await mediaDevices.getDisplayMedia({
            video: { resizeMode: "none" } as MediaTrackConstraints,
            audio: false,
        });
        const track = stream.getVideoTracks()[0];
        if (track === undefined) {
            stream.getTracks().forEach(candidate => candidate.stop());
            throw new Error("Screen sharing returned no video track.");
        }
        const settings = track.getSettings() as CaptureTrackSettings;
        const video = document.createElement("video");
        video.muted = true;
        video.playsInline = true;
        video.srcObject = stream;
        await video.play();
        if (video.videoWidth <= 0 || video.videoHeight <= 0) {
            stream.getTracks().forEach(candidate => candidate.stop());
            throw new Error("The shared screen has no video dimensions.");
        }
        const uiScale = captureUiScale(settings, video.videoWidth, video.videoHeight);
        const scope = captureScope(
            settings.displaySurface,
            video.videoWidth,
            video.videoHeight,
            uiScale,
        );
        this.#stream = stream;
        this.#video = video;
        this.#scope = scope;
        this.#uiScale = uiScale;
        track.addEventListener("ended", () => void this.stop(), { once: true });
        await this.#advertise();
        this.#pollTimer = globalThis.setInterval(() => void this.#poll(), 500);
        this.#advertiseTimer = globalThis.setInterval(() => void this.#advertise(), 20_000);
        this.#changed(true);
    }

    async stop(): Promise<void> {
        if (this.#pollTimer !== undefined) clearInterval(this.#pollTimer);
        if (this.#advertiseTimer !== undefined) clearInterval(this.#advertiseTimer);
        this.#pollTimer = undefined;
        this.#advertiseTimer = undefined;
        this.#stream?.getTracks().forEach(track => track.stop());
        this.#video?.removeAttribute("src");
        this.#stream = undefined;
        this.#video = undefined;
        this.#scope = undefined;
        await this.#advertise();
        this.#changed(false);
    }

    async #advertise(): Promise<void> {
        const scope = this.#scope;
        const path = `/profiles/${encodeURIComponent(this.#profileId())}`
            + "/client-tools/clients";
        await this.#json(path, {
            method: "POST",
            body: JSON.stringify({
                client_id: "web",
                device_id: "web",
                label: "Wheatley web client",
                capabilities: scope === undefined ? [] : [{
                    name: "capture_screen",
                    label: "Capture screen",
                    schema: {
                        type: "object",
                        properties: { scope: { type: "string", enum: [scope] } },
                    },
                    returns: ["image/png"],
                }],
                metadata: {
                    runner: "wheatley-web",
                    live_share: scope !== undefined,
                    ui_scale: this.#uiScale,
                },
            }),
        });
    }

    async #poll(): Promise<void> {
        if (this.#scope === undefined) return;
        try {
            const value = await this.#json(
                `/profiles/${encodeURIComponent(this.#profileId())}/client-tools/requests`
                    + "?status=pending&client_id=web&capability=capture_screen",
            ) as { readonly requests?: readonly { readonly request?: ClientToolRequest }[] };
            for (const detail of value.requests ?? []) {
                const request = detail.request;
                if (request === undefined || this.#handled.has(request.request_id)) continue;
                this.#handled.add(request.request_id);
                await this.#handle(request);
            }
        } catch (error: unknown) {
            console.error("Screen capture polling failed", error);
        }
    }

    async #handle(request: ClientToolRequest): Promise<void> {
        try {
            if (request.arguments.scope !== this.#scope)
                throw new Error(`Only ${this.#scope} is currently shared.`);
            const video = this.#video;
            if (video === undefined) throw new Error("Screen sharing ended.");
            const full = document.createElement("canvas");
            full.width = video.videoWidth;
            full.height = video.videoHeight;
            full.getContext("2d", { alpha: false })!.drawImage(video, 0, 0);
            const fullPng = await canvasPng(full);
            void this.#audio.playCaptureCue().catch((error: unknown) =>
                console.error("Capture chime failed", error));

            const maxLongEdge = request.arguments.model_max_long_edge_px;
            const scale = Math.min(
                1,
                request.arguments.model_pixels_per_logical_pixel / this.#uiScale,
                maxLongEdge / Math.max(full.width, full.height),
            );
            const modelWidth = Math.max(1, Math.round(full.width * scale));
            const modelHeight = Math.max(1, Math.round(full.height * scale));
            const fullArtifact = await this.#upload(
                request.request_id,
                fullPng,
                "screen-capture.png",
                "screen-capture",
                "screen_capture",
            );
            await this.#complete(request.request_id, true, [{
                ...fullArtifact,
                kind: "screen_capture",
                width: full.width,
                height: full.height,
                scope: this.#scope,
                ui_scale: this.#uiScale,
                model_width: modelWidth,
                model_height: modelHeight,
            }]);
        } catch (error: unknown) {
            const message = error instanceof Error ? error.message : String(error);
            await this.#complete(request.request_id, false, [], message);
        }
    }

    async #upload(
        requestId: string,
        blob: Blob,
        filename: string,
        artifactId: string,
        kind: string,
    ): Promise<Record<string, unknown> & { readonly url: string }> {
        const form = new FormData();
        form.append("artifact", blob, filename);
        form.append("artifact_id", artifactId);
        form.append("kind", kind);
        form.append("mime_type", "image/png");
        const response = await fetch(this.#endpoint.api(
            `/profiles/${encodeURIComponent(this.#profileId())}/client-tools/requests/`
                + `${encodeURIComponent(requestId)}/artifacts`,
        ), { method: "POST", body: form });
        if (!response.ok) throw new Error(await response.text());
        type UploadedArtifact = Record<string, unknown> & { readonly url: string };
        return (await response.json() as { artifact: UploadedArtifact }).artifact;
    }

    async #complete(
        requestId: string,
        ok: boolean,
        artifacts: readonly unknown[],
        message?: string,
    ): Promise<void> {
        await this.#json(
            `/profiles/${encodeURIComponent(this.#profileId())}/client-tools/requests/`
                + `${encodeURIComponent(requestId)}/result`,
            {
                method: "POST",
                body: JSON.stringify({
                    client_id: "web",
                    ok,
                    content: [{
                        type: "text",
                        text: ok ? "Captured the requested screen." : message,
                    }],
                    artifacts,
                    error: ok ? null : { code: "capture_failed", message },
                }),
            },
        );
    }

    async #json(path: string, init?: RequestInit): Promise<unknown> {
        const headers = new Headers(init?.headers);
        headers.set("Content-Type", "application/json");
        const response = await fetch(this.#endpoint.api(path), {
            ...init,
            headers,
        });
        if (!response.ok) throw new Error(await response.text());
        return await response.json();
    }
}

function captureUiScale(
    settings: CaptureTrackSettings,
    captureWidth: number,
    captureHeight: number,
): number {
    if (validUiScale(settings.screenPixelRatio)) return settings.screenPixelRatio;

    const widthScale = captureWidth / screen.width;
    const heightScale = captureHeight / screen.height;
    if (validUiScale(widthScale) && validUiScale(heightScale)
        && Math.abs(widthScale - heightScale) <= 0.15) {
        return (widthScale + heightScale) / 2;
    }
    return validUiScale(globalThis.devicePixelRatio) ? globalThis.devicePixelRatio : 1;
}

function captureScope(
    displaySurface: CaptureTrackSettings["displaySurface"],
    captureWidth: number,
    captureHeight: number,
    uiScale: number,
): ScreenScope {
    if (displaySurface === "monitor") return "active_display";
    if (displaySurface === "window" || displaySurface === "browser") return "active_window";

    const displayWidth = screen.width * uiScale;
    const displayHeight = screen.height * uiScale;
    const widthDifference = Math.abs(captureWidth - displayWidth) / displayWidth;
    const heightDifference = Math.abs(captureHeight - displayHeight) / displayHeight;
    return widthDifference <= 0.08 && heightDifference <= 0.08
        ? "active_display"
        : "active_window";
}

function validUiScale(value: number | undefined): value is number {
    return value !== undefined && Number.isFinite(value) && value >= 1 && value <= 4;
}

async function canvasPng(canvas: HTMLCanvasElement): Promise<Blob> {
    return await new Promise<Blob>((resolve, reject) => canvas.toBlob(blob => {
        if (blob === null) reject(new Error("Could not encode the screen as PNG."));
        else resolve(blob);
    }, "image/png"));
}
