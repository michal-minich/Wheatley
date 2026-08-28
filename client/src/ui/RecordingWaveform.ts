export interface AudioLevelSource {
    readonly readPeak: () => number;
}

export type RecordingWaveformMode = "hidden" | "live" | "sending";

interface PeakSample {
    readonly value: number;
    readonly capturedAt: number;
}

const liveHistoryMs = 4_000;

export class RecordingWaveform {
    readonly element: HTMLElement;
    readonly #canvas: HTMLCanvasElement;
    readonly #source: AudioLevelSource;
    readonly #peaks: PeakSample[] = [];
    #mode: RecordingWaveformMode = "hidden";
    #animationFrame: number | undefined;

    constructor(source: AudioLevelSource) {
        this.#source = source;
        this.#canvas = document.createElement("canvas");
        this.#canvas.setAttribute("aria-hidden", "true");
        this.element = document.createElement("div");
        this.element.classList.add("composer-recording-waveform");
        this.element.setAttribute("role", "img");
        this.element.hidden = true;
        this.element.append(this.#canvas);
    }

    render(mode: RecordingWaveformMode, label: string): void {
        this.element.setAttribute("aria-label", label);
        this.element.hidden = mode === "hidden";
        this.element.classList.toggle(
            "composer-recording-waveform-sending",
            mode === "sending",
        );
        if (mode === this.#mode)
            return;

        const previous = this.#mode;
        this.#mode = mode;
        if (mode === "live") {
            this.#peaks.length = 0;
            this.#startAnimation();
            return;
        }

        this.#cancelAnimation();
        if (mode === "sending") {
            this.#draw();
            return;
        }
        if (previous !== "hidden")
            this.#peaks.length = 0;
    }

    readonly #onAnimationFrame = (): void => {
        this.#animationFrame = undefined;
        if (this.#mode !== "live")
            return;
        const capturedAt = performance.now();
        this.#peaks.push({ value: this.#source.readPeak(), capturedAt });
        const firstVisible = this.#peaks.findIndex(
            sample => sample.capturedAt >= capturedAt - liveHistoryMs,
        );
        if (firstVisible > 0)
            this.#peaks.splice(0, firstVisible);
        this.#draw();
        this.#startAnimation();
    };

    #startAnimation(): void {
        if (this.#animationFrame === undefined)
            this.#animationFrame = requestAnimationFrame(this.#onAnimationFrame);
    }

    #cancelAnimation(): void {
        if (this.#animationFrame === undefined)
            return;
        cancelAnimationFrame(this.#animationFrame);
        this.#animationFrame = undefined;
    }

    #draw(): void {
        const frame = this.#canvas.getBoundingClientRect();
        const width = Math.max(1, Math.round(frame.width));
        const height = Math.max(1, Math.round(frame.height));
        const scale = window.devicePixelRatio;
        const pixelWidth = Math.round(width * scale);
        const pixelHeight = Math.round(height * scale);
        if (this.#canvas.width !== pixelWidth || this.#canvas.height !== pixelHeight) {
            this.#canvas.width = pixelWidth;
            this.#canvas.height = pixelHeight;
        }

        const context = this.#canvas.getContext("2d")!;
        context.setTransform(scale, 0, 0, scale, 0, 0);
        context.clearRect(0, 0, width, height);
        const centerY = Math.floor(height / 2) + 0.5;
        context.strokeStyle = "rgba(154, 168, 186, 0.16)";
        context.lineWidth = 1;
        context.beginPath();
        context.moveTo(0, centerY);
        context.lineTo(width, centerY);
        context.stroke();

        if (this.#peaks.length === 0)
            return;
        const peaks = displayPeaks(this.#peaks, width);
        const maxHalfHeight = Math.max(1, Math.floor(height / 2) - 3);
        const lastVisiblePeak = lastVisiblePeakIndex(peaks);
        for (let x = 0; x < peaks.length; x++) {
            if (peaks[x] === 0)
                continue;
            const peakHeight = Math.max(1, Math.ceil(peaks[x]! * maxHalfHeight));
            const alpha = lastVisiblePeak === 0 ? 1 : 0.25 + 0.75 * x / lastVisiblePeak;
            context.strokeStyle = `rgba(154, 168, 186, ${alpha})`;
            context.beginPath();
            context.moveTo(x + 0.5, centerY - peakHeight);
            context.lineTo(x + 0.5, centerY + peakHeight);
            context.stroke();
        }
    }
}

function displayPeaks(source: readonly PeakSample[], width: number): Float32Array {
    const peaks = new Float32Array(width);
    for (let i = 0; i < source.length; i++) {
        const x = Math.min(width - 1, Math.floor(i * width / source.length));
        peaks[x] = Math.max(peaks[x]!, source[i]!.value);
    }
    return peaks;
}

function lastVisiblePeakIndex(peaks: Float32Array): number {
    for (let i = peaks.length - 1; i >= 0; i--) {
        if (peaks[i] !== 0)
            return i;
    }
    return 0;
}
