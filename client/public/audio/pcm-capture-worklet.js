const targetSampleRate = 16_000;
const frameSamples = 320;

class WheatleyPcmCapture extends AudioWorkletProcessor {
    constructor() {
        super();
        this.samples = [];
        this.position = 0;
        this.frame = new Int16Array(frameSamples);
        this.frameLength = 0;
        this.peak = 0;
    }

    process(inputs, outputs) {
        const input = inputs[0]?.[0];
        const output = outputs[0]?.[0];
        if (output !== undefined)
            output.fill(0);
        if (input === undefined)
            return true;

        for (const sample of input)
            this.samples.push(sample);
        const ratio = sampleRate / targetSampleRate;
        while (this.position + 1 < this.samples.length) {
            const index = Math.floor(this.position);
            const fraction = this.position - index;
            const first = this.samples[index];
            const second = this.samples[index + 1];
            const sample = first + (second - first) * fraction;
            const bounded = Math.max(-1, Math.min(1, sample));
            this.frame[this.frameLength++] = bounded < 0
                ? Math.round(bounded * 32_768)
                : Math.round(bounded * 32_767);
            this.peak = Math.max(this.peak, Math.abs(bounded));
            this.position += ratio;
            if (this.frameLength === frameSamples) {
                const frame = this.frame.buffer;
                this.port.postMessage({ frame, peak: this.peak }, [frame]);
                this.frame = new Int16Array(frameSamples);
                this.frameLength = 0;
                this.peak = 0;
            }
        }
        const consumed = Math.floor(this.position);
        if (consumed > 0) {
            this.samples.splice(0, consumed);
            this.position -= consumed;
        }
        return true;
    }
}

registerProcessor("wheatley-pcm-capture", WheatleyPcmCapture);
