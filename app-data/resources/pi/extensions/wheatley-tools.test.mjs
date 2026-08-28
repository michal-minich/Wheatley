import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

process.env.WHEATLEY_API_BASE = "http://127.0.0.1:9/api";
process.env.WHEATLEY_PROFILE_ID = "tester";
process.env.WHEATLEY_SESSION_ID = "session-test";
process.env.WHEATLEY_TURN_ID = "turn-test";
process.env.WHEATLEY_REASONING_MODE = "off";
process.env.BRAVE_API_KEY = "test-key";

const piCli = realpathSync(execFileSync("which", ["pi"], { encoding: "utf8" }).trim());
const piDist = dirname(piCli);
const loaderUrl = pathToFileURL(resolve(piDist, "core/extensions/loader.js")).href;
const { loadExtensions } = await import(loaderUrl);
const extensionPath = resolve(import.meta.dirname, "wheatley-tools.ts");
const loaded = await loadExtensions([extensionPath], process.cwd());
assert.deepEqual(loaded.errors, []);
const tool = loaded.extensions[0].tools.get("image_search").definition;
const imageGenerationTool = loaded.extensions[0].tools.get("generate_image").definition;
const listGeneratedImagesTool = loaded.extensions[0].tools.get("list_generated_images").definition;
const loadGeneratedImageTool = loaded.extensions[0].tools.get("load_generated_image").definition;
const scheduledTaskTool = loaded.extensions[0].tools.get("create_scheduled_task").definition;
const listScheduledTasksTool = loaded.extensions[0].tools.get("list_scheduled_tasks").definition;
const getScheduledTaskTool = loaded.extensions[0].tools.get("get_scheduled_task").definition;
const providerRequestHandler = loaded.extensions[0].handlers
    .get("before_provider_request")[0];

const png = pngBytes(1, 1);

test("provider requests are captured after Wheatley overrides", async () => {
    let url;
    let capture;
    globalThis.fetch = async (requestedUrl, init) => {
        url = String(requestedUrl);
        capture = JSON.parse(init.body);
        return Response.json({ request_index: 1 });
    };
    const request = await providerRequestHandler({
        type: "before_provider_request",
        payload: {
            model: "ornith",
            messages: [{ role: "developer", content: "Pi\n\nWheatley" }],
            tools: [{ type: "function", function: { name: "read" } }],
        },
    });
    assert.equal(
        url,
        "http://127.0.0.1:9/api/profiles/tester/turns/turn-test/llm-requests"
            + "?session_id=session-test",
    );
    assert.equal(capture.request.messages[0].content, "Pi\n\nWheatley");
    assert.equal(capture.request.tools[0].function.name, "read");
    assert.match(capture.pi_version, /^\d+\.\d+\.\d+$/u);
    assert.deepEqual(request, capture.request);
});

test("generated image result keeps its path out of model-visible text", async () => {
    globalThis.fetch = async () => Response.json({
        generated_image_id: 1,
        item_id: "generated-image:1",
        kind: "generated_image",
        filename: "generated-01.png",
        media_type: "image/png",
        url: "/api/image.png",
        path: "profiles/tester/turns/turn-test/images/generated-01.png",
        sha256: "abc",
        byte_count: 24,
        width: 512,
        height: 512,
        seed: 42,
        quality: "low",
        aspect: "square",
        prompt: "A bonsai tree",
    });
    const result = await imageGenerationTool.execute(
        "generate-1",
        { prompt: "A bonsai tree", aspect: "square", quality: "low" },
        AbortSignal.timeout(1000),
    );
    assert.equal(result.content[0].text, "Generated image 1.");
    assert.equal(result.content[0].text.includes(result.details.path), false);
    assert.equal(result.details.path.endsWith("generated-01.png"), true);
});

test("generated image listing exposes stable IDs and descriptions only", async () => {
    globalThis.fetch = async () => Response.json({ images: [{
        generated_image_id: 3,
        item_id: "generated-image:3",
        kind: "generated_image",
        filename: "generated-03.png",
        media_type: "image/png",
        url: "/api/image-3.png",
        path: "private/image-3.png",
        sha256: "abc",
        byte_count: 24,
        width: 768,
        height: 512,
        seed: 42,
        quality: "medium",
        aspect: "landscape",
        prompt: "A wheat field",
    }] });
    const result = await listGeneratedImagesTool.execute(
        "list-images-1",
        {},
        AbortSignal.timeout(1000),
    );
    assert.deepEqual(JSON.parse(result.content[0].text), [{
        generated_image_id: 3,
        prompt: "A wheat field",
        width: 768,
        height: 512,
    }]);
    assert.equal(result.content[0].text.includes("private/image-3.png"), false);
});

test("generated image loading attaches exactly the selected image", async () => {
    const calls = [];
    globalThis.fetch = async url => {
        calls.push(String(url));
        if (String(url).includes("generated-images?")) return Response.json({ images: [{
            generated_image_id: 2,
            item_id: "generated-image:2",
            kind: "generated_image",
            filename: "generated-02.png",
            media_type: "image/png",
            url: "/api/image-2.png",
            path: "private/image-2.png",
            sha256: "abc",
            byte_count: png.length,
            width: 1,
            height: 1,
            seed: 42,
            quality: "low",
            aspect: "square",
            prompt: "A bonsai tree",
        }] });
        return new Response(png, { headers: { "Content-Type": "image/png" } });
    };
    const result = await loadGeneratedImageTool.execute(
        "load-image-1",
        { generated_image_id: 2 },
        AbortSignal.timeout(1000),
    );
    assert.equal(result.content[0].text, "Generated image 2.");
    assert.equal(result.content.filter(part => part.type === "image").length, 1);
    assert.equal(result.details.generated_image_id, 2);
    assert.equal(calls.length, 2);
});

test("new-session task creation leaves model selection to Wheatley", async () => {
    let request;
    globalThis.fetch = async (_url, init) => {
        request = JSON.parse(init.body);
        return Response.json({
            task: { display_text: request.task.display_text },
        });
    };
    const result = await scheduledTaskTool.execute(
        "schedule-1",
        {
            display_text: "Morning digest",
            task_text: "Prepare the morning digest.",
            target: "new_session",
            schedule: { kind: "once", when: { kind: "after", seconds: 60 } },
        },
        AbortSignal.timeout(1000),
    );
    assert.equal(request.model, undefined);
    assert.equal(request.task.target, "new_session");
    assert.equal(result.content[0].text, "Scheduled task created: Morning digest.");
});

test("task creation exposes the server's factual error message", async () => {
    globalThis.fetch = async () => new Response(JSON.stringify({
        error: {
            message: "Current chat has no selected model.",
        },
    }), { status: 400, statusText: "Bad Request" });
    await assert.rejects(
        scheduledTaskTool.execute(
            "schedule-2",
            {
                display_text: "Morning digest",
                task_text: "Prepare the morning digest.",
                target: "new_session",
                schedule: { kind: "once", when: { kind: "after", seconds: 60 } },
            },
            AbortSignal.timeout(1000),
        ),
        /Current chat has no selected model/u,
    );
});

test("scheduled-task listing exposes every compact task record to the model", async () => {
    globalThis.fetch = async () => Response.json({
        tasks: [
            {
                id: "schedule_first",
                state: "enabled",
                quick_status: "ok",
                display_text: "First task",
                target: "active_user_session",
                schedule_text: "Every hour",
                next_run_at: "2026-08-17T22:00:00Z",
                has_run: true,
                last_run_status: "completed",
            },
            {
                id: "schedule_second",
                state: "disabled",
                quick_status: "disabled",
                display_text: "Second task",
                target: "new_session",
                schedule_text: "Tomorrow at 09:00",
                has_run: false,
            },
        ],
    });
    const result = await listScheduledTasksTool.execute(
        "schedule-list-1",
        {},
        AbortSignal.timeout(1000),
    );
    assert.equal(result.content[0].text, [
        "Scheduled tasks (2):",
        "1. id=schedule_first; title=\"First task\"; state=enabled; quick_status=ok; target=active_user_session; schedule=\"Every hour\"; next_run_at=2026-08-17T22:00:00Z; has_run=true; last_run_status=completed",
        "2. id=schedule_second; title=\"Second task\"; state=disabled; quick_status=disabled; target=new_session; schedule=\"Tomorrow at 09:00\"; has_run=false",
    ].join("\n"));
});

test("scheduled-task detail exposes the full task to the model", async () => {
    globalThis.fetch = async () => Response.json({
        id: "schedule_first",
        state: "disabled",
        quick_status: "disabled",
        display_text: "Minute joke",
        target: "active_user_session",
        schedule_text: "Every 300 seconds (clock-anchored)",
        has_run: true,
        last_run_status: "completed",
        task: {
            display_text: "Minute joke",
            state: "disabled",
            task_text: "Tell me one short joke.",
            target: { kind: "active_user_session" },
            schedule: { kind: "fixed_interval", every_seconds: 300 },
            reasoning_mode: "low",
            created: { at: "2026-08-17T20:38:20Z" },
            last_run: { status: "completed", session_id: "2026/08/18/10_18_32" },
        },
    });
    const result = await getScheduledTaskTool.execute(
        "schedule-get-1",
        { id: "schedule_first" },
        AbortSignal.timeout(1000),
    );
    assert.match(result.content[0].text, /task_text="Tell me one short joke\."/u);
    assert.match(result.content[0].text, /schedule="Every 300 seconds \(clock-anchored\)"/u);
    assert.equal(result.details.task_text, "Tell me one short joke.");
    assert.equal(result.details.schedule.kind, "fixed_interval");
    assert.equal(result.content[0].text.includes("Tell me one short joke."), true);
});

test("image search defaults to exactly one inspected image", async () => {
    const calls = [];
    globalThis.fetch = async (url, init) => {
        calls.push(String(url));
        if (String(url).startsWith("https://api.search.brave.com/")) {
            return Response.json({ results: candidates(3) });
        }
        if (String(url).startsWith(process.env.WHEATLEY_API_BASE))
            return storedWebImageResponse(init);
        return new Response(png, { headers: { "Content-Type": "image/png" } });
    };
    const result = await tool.execute("call-1", { query: "capybara" }, AbortSignal.timeout(1000));
    assert.equal(result.details.count, 1);
    assert.equal(result.content.filter(part => part.type === "image").length, 1);
    assert.equal(calls.filter(url => url.startsWith("https://8.8.8.8/")).length, 1);
    const brave = new URL(calls[0]);
    assert.equal(brave.searchParams.get("safesearch"), "strict");
});

test("image search removes resolution and download boilerplate from its display title", async () => {
    globalThis.fetch = async (url, init) => {
        if (String(url).startsWith("https://api.search.brave.com/")) {
            const candidate = candidates(1)[0];
            candidate.title = "JFrog Logo Clipart (600x609), Png Download";
            return Response.json({ results: [candidate] });
        }
        if (String(url).startsWith(process.env.WHEATLEY_API_BASE))
            return storedWebImageResponse(init);
        return new Response(png, { headers: { "Content-Type": "image/png" } });
    };
    const result = await tool.execute(
        "call-title",
        { query: "JFrog logo" },
        AbortSignal.timeout(1000),
    );
    assert.equal(result.details.images[0].title, "JFrog Logo Clipart");
    assert.match(result.content[0].text, /^Image 1: JFrog Logo Clipart\n/u);
});

test("image comparison exposes exactly two images", async () => {
    let downloads = 0;
    globalThis.fetch = async (url, init) => {
        if (String(url).startsWith("https://api.search.brave.com/")) {
            return Response.json({ results: candidates(3) });
        }
        if (String(url).startsWith(process.env.WHEATLEY_API_BASE))
            return storedWebImageResponse(init);
        downloads += 1;
        return new Response(png, { headers: { "Content-Type": "image/png" } });
    };
    const result = await tool.execute(
        "call-2",
        { query: "oak versus beech", count: 2 },
        AbortSignal.timeout(1000),
    );
    assert.equal(result.details.count, 2);
    assert.equal(result.content.filter(part => part.type === "image").length, 2);
    assert.equal(downloads, 2);
});

test("image search rejects counts above the fixed boundary", async () => {
    await assert.rejects(
        tool.execute("call-3", { query: "too many", count: 4 }, AbortSignal.timeout(1000)),
        /from 1 through 3/,
    );
});

test("a broken candidate is skipped without exposing an extra image", async () => {
    let downloads = 0;
    globalThis.fetch = async (url, init) => {
        if (String(url).startsWith("https://api.search.brave.com/")) {
            return Response.json({ results: candidates(2) });
        }
        if (String(url).startsWith(process.env.WHEATLEY_API_BASE))
            return storedWebImageResponse(init);
        downloads += 1;
        return new Response(downloads === 1 ? Uint8Array.from([1, 2, 3]) : png, {
            headers: { "Content-Type": "image/png" },
        });
    };
    const result = await tool.execute("call-4", { query: "fallback" }, AbortSignal.timeout(1000));
    assert.equal(result.details.count, 1);
    assert.equal(downloads, 2);
    assert.equal(result.content.filter(part => part.type === "image").length, 1);
});

test("a WebP candidate is skipped for LM Studio portability", async () => {
    let downloads = 0;
    globalThis.fetch = async (url, init) => {
        if (String(url).startsWith("https://api.search.brave.com/")) {
            return Response.json({ results: candidates(2) });
        }
        if (String(url).startsWith(process.env.WHEATLEY_API_BASE))
            return storedWebImageResponse(init);
        downloads += 1;
        if (downloads === 1) {
            return new Response(Uint8Array.from([
                82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80,
            ]), { headers: { "Content-Type": "image/webp" } });
        }
        return new Response(png, { headers: { "Content-Type": "image/png" } });
    };
    const result = await tool.execute(
        "call-5",
        { query: "portable image" },
        AbortSignal.timeout(1000),
    );
    assert.equal(result.details.count, 1);
    assert.equal(result.details.images[0].media_type, "image/png");
    assert.equal(downloads, 2);
});

test("an oversized decoded image is skipped", async () => {
    let downloads = 0;
    globalThis.fetch = async (url, init) => {
        if (String(url).startsWith("https://api.search.brave.com/")) {
            return Response.json({ results: candidates(2) });
        }
        if (String(url).startsWith(process.env.WHEATLEY_API_BASE))
            return storedWebImageResponse(init);
        downloads += 1;
        return new Response(downloads === 1 ? pngBytes(6000, 6000) : png, {
            headers: { "Content-Type": "image/png" },
        });
    };
    const result = await tool.execute(
        "call-6",
        { query: "safe pixels" },
        AbortSignal.timeout(1000),
    );
    assert.equal(result.details.count, 1);
    assert.equal(downloads, 2);
});

function candidates(count) {
    return Array.from({ length: count }, (_, index) => ({
        title: `Image ${index + 1}`,
        url: `https://example.com/source-${index + 1}`,
        thumbnail: { src: `https://8.8.8.8/image-${index + 1}.png` },
        properties: { url: `https://example.com/image-${index + 1}.png` },
    }));
}

function storedWebImageResponse(init) {
    const request = JSON.parse(init.body);
    return Response.json({
        kind: "web_image",
        filename: "web-01.png",
        media_type: request.media_type,
        url: "/api/profiles/tester/turns/turn-test/images/web-01.png",
        path: "profiles/tester/turns/turn-test/images/web-01.png",
        sha256: "abc",
        byte_count: 24,
        width: 1,
        height: 1,
        title: request.title,
        source_url: request.source_url,
        original_image_url: request.original_image_url,
    });
}

function pngBytes(width, height) {
    return Uint8Array.from([
        137, 80, 78, 71, 13, 10, 26, 10,
        0, 0, 0, 13, 73, 72, 68, 82,
        (width >>> 24) & 255, (width >>> 16) & 255,
        (width >>> 8) & 255, width & 255,
        (height >>> 24) & 255, (height >>> 16) & 255,
        (height >>> 8) & 255, height & 255,
    ]);
}
