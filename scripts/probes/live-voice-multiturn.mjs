#!/usr/bin/env node

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const profileId = process.argv[2] ?? "tooltest";
const apiBase = process.env.WHEATLEY_API_BASE ?? "http://127.0.0.1:8765/api";
const repoRoot = resolve(new URL("../..", import.meta.url).pathname);
const ffmpeg = join(repoRoot, "app-data/tools/macos-arm64/bin/ffmpeg");
const prompts = [
    "Reply with exactly voice zero.",
    "Also include the exact word alpha.",
    "Also include the exact word beta.",
];
const temporaryRoot = await mkdtemp(join(tmpdir(), "wheatley-live-voice-"));

try {
    const clientConfig = await getJson(`${apiBase}/config/clients/web`);
    const profileConfig = clientConfig.profiles.find(profile => profile.profile_id === profileId);
    check(profileConfig !== undefined, `Profile ${profileId} has no web client config.`);
    const startup = await startSession(profileConfig.model);
    await verifyEmptyCandidateRetry(
        startup.session_id,
        profileConfig.model,
        profileConfig.reasoning_mode,
    );
    const audio = [];
    for (let index = 0; index < prompts.length; index++)
        audio.push(await synthesizePcm(prompts[index], index));

    const turns = audio.map((pcm, index) => createTurn(
        startup.session_id,
        pcm,
        index,
        profileConfig.model,
        profileConfig.reasoning_mode,
    ));
    for (const turn of turns)
        await turn.committed;
    const completed = await Promise.all(turns.map(turn => turn.completed));
    const presentation = await getJson(
        `${apiBase}/profiles/${encodeURIComponent(profileId)}/presentation`
        + `?session_id=${encodeURIComponent(startup.session_id)}`,
    );
    const failures = presentation.entries.filter(entry => entry.kind === "failed");
    check(failures.length === 0, `Session presentation contains ${failures.length} failures.`);
    check(completed.every(turn => turn.transcript.length > 0), "A transcript was empty.");
    check(completed[1].transcript.toLowerCase().includes("alpha"), "Alpha steer was lost.");
    check(completed[2].transcript.toLowerCase().includes("beta"), "Beta steer was lost.");
    process.stdout.write(`${JSON.stringify({
        status: "passed",
        profile_id: profileId,
        session_id: startup.session_id,
        empty_candidate_retry: "passed",
        turns: completed,
        presentation_entries: presentation.entries.length,
        failures: failures.length,
    }, null, 2)}\n`);
} finally {
    await rm(temporaryRoot, { recursive: true, force: true });
}

async function startSession(model) {
    const response = await fetch(`${apiBase}/profiles/${encodeURIComponent(profileId)}/startup/stream`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            mode: "chat",
            model,
            language: "en",
            resume_session_id: "",
        }),
    });
    check(response.ok, `Startup failed with HTTP ${response.status}.`);
    const events = parseSse(await response.text());
    const done = events.find(event => event.name === "done");
    check(done !== undefined, "Startup stream had no done event.");
    const result = JSON.parse(done.data);
    check(result.ok === true && result.session_id, "Startup did not create a session.");
    return result;
}

async function synthesizePcm(text, index) {
    const response = await fetch(`${apiBase}/profiles/${encodeURIComponent(profileId)}/tts`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, language: "en" }),
    });
    check(response.ok, `TTS failed with HTTP ${response.status}.`);
    const artifact = await response.json();
    const audioResponse = await fetch(new URL(artifact.audio_url, apiBase));
    check(audioResponse.ok, `Generated audio failed with HTTP ${audioResponse.status}.`);
    const encodedPath = join(temporaryRoot, `${index}.opus`);
    const pcmPath = join(temporaryRoot, `${index}.pcm`);
    await writeFile(encodedPath, Buffer.from(await audioResponse.arrayBuffer()));
    await run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-i", encodedPath,
        "-af", "adelay=200,apad=pad_dur=1.5",
        "-ac", "1", "-ar", "16000", "-f", "s16le", pcmPath, "-y",
    ]);
    return await readFile(pcmPath);
}

function verifyEmptyCandidateRetry(sessionId, model, reasoningMode) {
    return new Promise((resolvePromise, reject) => {
        const submissionId = `probe-empty-${crypto.randomUUID()}`;
        const wsUrl = apiBase.replace(/^http/u, "ws")
            + `/profiles/${encodeURIComponent(profileId)}/turns/audio/live`;
        const socket = new WebSocket(wsUrl);
        let settled = false;
        let stopSent = false;
        const timeout = setTimeout(
            () => fail(new Error("Empty live candidate retry timed out.")),
            15_000,
        );
        const finish = () => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            socket.send(JSON.stringify({ type: "cancel" }));
            socket.close(1000, "Empty candidate retry verified");
            resolvePromise();
        };
        const fail = error => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            socket.close();
            reject(error);
        };
        socket.addEventListener("open", () => socket.send(JSON.stringify({
            type: "start",
            session_id: sessionId,
            submission_id: submissionId,
            device_id: "probe-empty-candidate",
            text: "",
            language: "en",
            load_memory: true,
            reasoning_mode: reasoningMode,
            model,
            after_sequence: 0,
            purpose: "turn",
            prewarm_existing_session: true,
            silence_seconds: 1,
            audio_input_selector: "synthetic-probe",
            audio_input_label: "Synthetic probe",
            audio: {
                format: "pcm_s16le",
                sample_rate: 16000,
                channels: 1,
                frame_ms: 20,
                bitrate: 0,
                application: "",
                complexity: 0,
                container: "",
            },
        })));
        socket.addEventListener("message", message => {
            try {
                const event = JSON.parse(String(message.data));
                if (event.type !== "voice_event") return;
                if (event.kind === "listening_started" && !stopSent) {
                    stopSent = true;
                    socket.send(JSON.stringify({ type: "stop" }));
                } else if (event.kind === "listening_retry") {
                    finish();
                } else if (event.kind === "failed") {
                    fail(new Error(event.payload.message));
                }
            } catch (error) {
                fail(error);
            }
        });
        socket.addEventListener("error", () => fail(new Error("Empty candidate socket failed.")));
    });
}

function createTurn(sessionId, pcm, index, model, reasoningMode) {
    const submissionId = `probe-live-${crypto.randomUUID()}`;
    let resolveCommitted;
    let rejectCommitted;
    let resolveCompleted;
    let rejectCompleted;
    const committed = new Promise((resolve, reject) => {
        resolveCommitted = resolve;
        rejectCommitted = reject;
    });
    const completed = new Promise((resolve, reject) => {
        resolveCompleted = resolve;
        rejectCompleted = reject;
    });
    const wsUrl = apiBase.replace(/^http/u, "ws")
        + `/profiles/${encodeURIComponent(profileId)}/turns/audio/live`;
    const socket = new WebSocket(wsUrl);
    let transcript = "";
    let sent = false;
    const fail = error => {
        rejectCommitted(error);
        rejectCompleted(error);
        socket.close();
    };
    const timeout = setTimeout(() => fail(new Error(`Turn ${index + 1} timed out.`)), 180_000);
    socket.addEventListener("open", () => socket.send(JSON.stringify({
        type: "start",
        session_id: sessionId,
        submission_id: submissionId,
        device_id: "probe-live-voice",
        text: "",
        language: "en",
        load_memory: true,
        reasoning_mode: reasoningMode,
        model,
        after_sequence: 0,
        purpose: "turn",
        prewarm_existing_session: true,
        silence_seconds: 1,
        audio_input_selector: "synthetic-probe",
        audio_input_label: "Synthetic probe",
        audio: {
            format: "pcm_s16le",
            sample_rate: 16000,
            channels: 1,
            frame_ms: 20,
            bitrate: 0,
            application: "",
            complexity: 0,
            container: "",
        },
    })));
    socket.addEventListener("message", async message => {
        try {
            const event = JSON.parse(String(message.data));
            if (event.type === "voice_event") {
                if (["listening_started", "listening_retry"].includes(event.kind) && !sent) {
                    sent = true;
                    await sendPcm(socket, pcm);
                } else if (event.kind === "transcript_accepted") {
                    transcript = (event.payload.user_text || event.payload.text || "").trim();
                    socket.send(JSON.stringify({
                        type: "commit",
                        reasoning_mode: reasoningMode,
                        model,
                    }));
                    resolveCommitted({ submissionId, transcript });
                } else if (event.kind === "failed") {
                    fail(new Error(event.payload.message));
                }
                return;
            }
            if (event.type !== "conversation_event") return;
            const conversation = event.event;
            if (conversation.kind === "completed") {
                clearTimeout(timeout);
                socket.close(1000, "Done");
                resolveCompleted({
                    index: index + 1,
                    submission_id: submissionId,
                    turn_id: conversation.turn_id,
                    transcript,
                });
            } else if (conversation.kind === "failed") {
                fail(new Error(conversation.payload.message));
            }
        } catch (error) {
            fail(error);
        }
    });
    socket.addEventListener("error", () => fail(new Error(`Turn ${index + 1} socket failed.`)));
    return { committed, completed };
}

async function sendPcm(socket, pcm) {
    const frameBytes = 640;
    for (let offset = 0; offset < pcm.length; offset += frameBytes) {
        socket.send(pcm.subarray(offset, Math.min(offset + frameBytes, pcm.length)));
        await new Promise(resolve => setTimeout(resolve, 20));
    }
}

async function getJson(url) {
    const response = await fetch(url);
    check(response.ok, `${url} failed with HTTP ${response.status}.`);
    return await response.json();
}

function parseSse(text) {
    return text.trim().split(/\r?\n\r?\n/u).map(block => {
        let name = "message";
        const data = [];
        for (const line of block.split(/\r?\n/u)) {
            if (line.startsWith("event:")) name = line.slice(6).trim();
            if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
        }
        return { name, data: data.join("\n") };
    });
}

function run(command, args) {
    return new Promise((resolvePromise, reject) => {
        const child = spawn(command, args, { stdio: "inherit" });
        child.once("error", reject);
        child.once("exit", code => {
            if (code === 0) resolvePromise();
            else reject(new Error(`${command} exited ${code}.`));
        });
    });
}

function check(condition, message) {
    if (!condition) throw new Error(message);
}
