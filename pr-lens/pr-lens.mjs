// pr-lens.mjs - the two steps pr-lens.sh hands to Node.
//
// Usage: node pr-lens.mjs <analyze | comment>
//
// pr-lens.sh copies this file, lib.mjs, and prompt.md next to the installed
// packages, so the imports resolve from the lockfile.
//
// Env inputs:
//   WORK               work directory, shared with pr-lens.sh             (analyze, comment)
//   GITHUB_REPOSITORY  owner/repo                                         (analyze)
//   GITHUB_SERVER_URL  default https://github.com                         (analyze)
//   PR_NUMBER          pull request number                                (analyze)
//   BASE_SHA           pull request base commit                           (analyze)
//   HEAD_SHA           pull request head commit                           (analyze)
//   PULL_REQUEST_FILE  JSON with the pull request's title and body        (analyze)
//   PR_LENS_BASE_URL   OpenAI-compatible endpoint base                    (analyze)
//   PR_LENS_MODEL      model name on that endpoint                        (analyze)
//   PR_LENS_API_KEY    key for that endpoint                              (analyze)
//   ASSETS             render output directory                            (comment)
//   ASSETS_URL         base URL of the published SVGs, empty = none       (comment)
//   BRANDING           true | false, the PR Lens footer (default true)    (comment)
//
// Files written:
//   ${WORK}/graph.json         the document to render                      (analyze)
//   ${WORK}/choice.json        {drawing, reason, runtimeLines}              (analyze)
//   ${WORK}/comment-body.md    the comment below its marker lines           (comment)

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { safeParseGraphDoc } from "@coldtea/pr-lens-schema";
import {
  applyKnownFields,
  buildJsonRepairPrompt,
  buildRepairPrompt,
  buildUserPrompt,
  chooseDrawing,
  composeComment,
  normalizePayloadSamples,
  parseNumstat,
  readJsonObject,
} from "./lib.mjs";

const MAX_DIFF_BYTES = 400_000;
const MAX_OUTPUT_TOKENS = 32_768;
// The job times out at 15 minutes. Leave room for install, render, and publish.
const ANALYZE_BUDGET_MS = 10 * 60_000;
const REQUEST_TIMEOUT_MS = 5 * 60_000;
const MAX_REQUEST_ATTEMPTS = 3;
// One repair round. A model that cannot fix a named path in one go does not fix it in three.
const MAX_DOCUMENT_ATTEMPTS = 2;

const started = Date.now();
const elapsed = () => `[${String(Math.round((Date.now() - started) / 1000)).padStart(3)}s]`;

const RERUN = "re-run the workflow";
const CHECK_MODEL = "re-run the workflow, and if it fails again check PR_LENS_BASE_URL, PR_LENS_MODEL, and PR_LENS_API_KEY in Infisical";

// A failure the reader can act on. `next` says what to do.
class Failure extends Error {
  constructor(message, next = RERUN) {
    super(message);
    this.next = next;
  }
}

const env = (name) => {
  const value = process.env[name];
  if (value === undefined || value === "") throw new Failure(`${name} is not set`, "this is a bug in pr-lens.sh, which must export it");
  return value;
};

const git = (args) => execFileSync("git", args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });

const collectDiff = (base, head) => {
  const files = parseNumstat(git(["diff", "--numstat", "--find-renames", base, head]));
  const patch = git(["diff", "--no-color", "--find-renames", "--unified=3", base, head]);
  const withinBudget = Buffer.byteLength(patch, "utf8") <= MAX_DIFF_BYTES;
  const sum = (key) => files.reduce((total, file) => total + (file[key] ?? 0), 0);
  return {
    files,
    additions: sum("additions"),
    deletions: sum("deletions"),
    patch: withinBudget ? patch : Buffer.from(patch, "utf8").subarray(0, MAX_DIFF_BYTES).toString("utf8"),
    truncatedAt: withinBudget ? undefined : MAX_DIFF_BYTES,
  };
};

// Reads a server-sent event stream of chat completion chunks.
const readStream = async (body) => {
  const decoder = new TextDecoder();
  let buffer = "";
  let content = "";
  let usage;
  let finish;
  const take = (line) => {
    if (!line.startsWith("data:")) return;
    const data = line.slice(5).trim();
    if (data === "" || data === "[DONE]") return;
    const chunk = JSON.parse(data);
    if (chunk.error) throw new Error(`the stream carried an error: ${JSON.stringify(chunk.error).slice(0, 200)}`);
    if (chunk.usage) usage = chunk.usage;
    const choice = chunk.choices?.[0];
    content += choice?.delta?.content ?? "";
    finish = choice?.finish_reason ?? finish;
  };
  for await (const bytes of body) {
    buffer += decoder.decode(bytes, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop();
    lines.forEach(take);
  }
  take(buffer);
  return { content, usage, finish };
};

// Streams, because a proxy in front of a model endpoint cuts a request that
// sends no bytes for about two minutes, and a model that thinks longer than
// that never answers a request that waits for the whole body.
const complete = async (messages) => {
  const url = `${env("PR_LENS_BASE_URL").replace(/\/+$/, "")}/chat/completions`;
  const body = JSON.stringify({
    model: env("PR_LENS_MODEL"),
    stream: true,
    stream_options: { include_usage: true },
    max_tokens: MAX_OUTPUT_TOKENS,
    messages,
  });
  let last = "";
  for (let attempt = 1; attempt <= MAX_REQUEST_ATTEMPTS; attempt += 1) {
    const remaining = ANALYZE_BUDGET_MS - (Date.now() - started);
    if (remaining < 30_000) break;
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${env("PR_LENS_API_KEY")}`, "content-type": "application/json" },
        body,
        signal: AbortSignal.timeout(Math.min(remaining, REQUEST_TIMEOUT_MS)),
      });
      if (!response.ok) {
        const text = (await response.text()).replace(/\s+/g, " ").slice(0, 200);
        last = `HTTP ${response.status}`;
        if (response.status !== 429 && response.status < 500) {
          throw new Failure(`the model endpoint refused the request with HTTP ${response.status}: ${text}`, CHECK_MODEL);
        }
      } else {
        const answer = await readStream(response.body);
        if (answer.content.trim() !== "") {
          const tokens = answer.usage?.completion_tokens ?? "?";
          console.log(`${elapsed()} model answered tokens=${tokens} finish=${answer.finish ?? "?"}`);
          return answer.content;
        }
        last = "an empty answer";
      }
    } catch (error) {
      if (error instanceof Failure) throw error;
      last = error instanceof Error ? error.message : String(error);
    }
    if (attempt < MAX_REQUEST_ATTEMPTS) {
      console.log(`${elapsed()} model request failed (${last}) - retry ${attempt}/${MAX_REQUEST_ATTEMPTS - 1} in ${attempt * 10}s`);
      await new Promise((resolve) => setTimeout(resolve, attempt * 10_000));
    }
  }
  throw new Failure(`the model endpoint failed ${MAX_REQUEST_ATTEMPTS} times, last with ${last}`, CHECK_MODEL);
};

const extract = async (system, user, known) => {
  const messages = [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
  for (let attempt = 1; attempt <= MAX_DOCUMENT_ATTEMPTS; attempt += 1) {
    const last = attempt === MAX_DOCUMENT_ATTEMPTS;
    const text = await complete(messages);
    const read = readJsonObject(text);
    if (!read.ok) {
      if (last) throw new Failure(`the model did not answer with a JSON object, twice: ${read.reason}`);
      console.log(`${elapsed()} the answer is not JSON - asking for a correction`);
      messages.push({ role: "assistant", content: text }, { role: "user", content: buildJsonRepairPrompt(read.reason) });
      continue;
    }
    const parsed = safeParseGraphDoc(applyKnownFields(normalizePayloadSamples(read.value), known));
    if (parsed.ok) return parsed.value;
    if (last) throw new Failure(`the model produced a document that does not validate, twice: ${parsed.error.message.slice(0, 500)}`);
    console.log(`${elapsed()} the document did not validate - asking for a correction`);
    messages.push({ role: "assistant", content: text }, { role: "user", content: buildRepairPrompt(parsed.error.message) });
  }
  throw new Failure("extraction produced no document");
};

const analyze = async () => {
  const work = env("WORK");
  const repository = env("GITHUB_REPOSITORY");
  const prNumber = Number(env("PR_NUMBER"));
  const head = env("HEAD_SHA");
  const base = git(["merge-base", env("BASE_SHA"), head]).trim();
  const pullRequest = JSON.parse(readFileSync(env("PULL_REQUEST_FILE"), "utf8"));
  const diff = collectDiff(base, head);
  if (diff.files.length === 0) throw new Failure(`${base} and ${head} have the same content`, "push a commit that changes something, then re-run");

  const here = dirname(fileURLToPath(import.meta.url));
  const system = readFileSync(join(here, "prompt.md"), "utf8");
  const jsonSchema = readFileSync(join(here, "node_modules/@coldtea/pr-lens-schema/json-schema/graph-doc.schema.json"), "utf8");
  const user = buildUserPrompt({ repository, base, head, pullRequest, diff, jsonSchema });
  const [owner, name] = repository.split("/");
  const server = process.env.GITHUB_SERVER_URL || "https://github.com";

  console.log(
    `${elapsed()} diff files=${diff.files.length} +${diff.additions} -${diff.deletions}${diff.truncatedAt === undefined ? "" : " (truncated)"} prompt=${Buffer.byteLength(user, "utf8")}B model=${env("PR_LENS_MODEL")}`,
  );

  const document = await extract(system, user, {
    provenance: {
      repo: { owner, name, host: new URL(server).host },
      base: { sha: base },
      head: { sha: head },
      pullRequest: { number: prNumber, url: `${server}/${repository}/pull/${prNumber}` },
      generator: { name: "lazco-ci-actions/pr-lens", version: "1", model: env("PR_LENS_MODEL") },
    },
    lenses: ["architecture", "data-flow"],
    stats: { filesChanged: diff.files.length, additions: diff.additions, deletions: diff.deletions },
    generatedAt: new Date().toISOString(),
  });

  const choice = chooseDrawing(document, diff.files);
  const checked = safeParseGraphDoc(choice.document);
  if (!checked.ok) {
    throw new Failure(
      `choosing the ${choice.drawing} drawing broke the document: ${checked.error.message.slice(0, 500)}`,
      "this is a bug in chooseDrawing in lib.mjs - report it with this log",
    );
  }
  writeFileSync(join(work, "graph.json"), JSON.stringify(checked.value, null, 2));
  writeFileSync(
    join(work, "choice.json"),
    JSON.stringify({ drawing: choice.drawing, reason: choice.reason, runtimeLines: choice.runtimeLines }),
  );
  console.log(
    `${elapsed()} drawing=${choice.drawing} reason=${choice.reason} runtime-lines=${choice.runtimeLines} nodes=${document.nodes.length} edges=${document.edges.length} flows=${document.flows.length}`,
  );
};

const comment = () => {
  const work = env("WORK");
  const assets = env("ASSETS");
  const choice = JSON.parse(readFileSync(join(work, "choice.json"), "utf8"));
  const drawn = choice.drawing !== "none";
  // The renderer applies the repo's corrections, so the drawn document is the
  // one whose names match the pictures.
  const graphPath = drawn && existsSync(join(assets, "drawn.graph.json")) ? join(assets, "drawn.graph.json") : join(work, "graph.json");
  const body = composeComment({
    graph: JSON.parse(readFileSync(graphPath, "utf8")),
    choice,
    manifest: drawn ? JSON.parse(readFileSync(join(assets, "manifest.json"), "utf8")) : undefined,
    assetsUrl: drawn ? env("ASSETS_URL") : undefined,
    branding: (process.env.BRANDING ?? "true") !== "false",
  });
  writeFileSync(join(work, "comment-body.md"), body);
};

const step = process.argv[2];
try {
  if (step === "analyze") await analyze();
  else if (step === "comment") comment();
  else throw new Failure(`unknown step '${step}'`, "call it with analyze or comment");
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  const next = error instanceof Failure ? error.next : "this is a bug in pr-lens.mjs - report it with this log";
  console.log(`::error title=PR Lens ${step ?? ""} failed::${message.replace(/\n/g, " ")} - ${next}`);
  process.exit(1);
}
