// Pure parts of pr-lens.mjs: no network, no files, no environment, so the
// self-test can run them on fixtures.
//
// readJsonObject, applyKnownFields, normalizePayloadSamples, and the repair
// prompts are adapted from coldteadotai/pr-lens packages/cli (MIT, see
// LICENSE-pr-lens).

import { SCHEMA_VERSION } from "@coldtea/pr-lens-schema";

// A flow shorter than this restates the summary instead of explaining it.
export const MIN_FLOW_STEPS = 3;
export const MAX_FLOWS = 2;
// An architecture view below this is a box or two with nothing between them.
export const MIN_ARCHITECTURE_NODES = 3;
export const MIN_ARCHITECTURE_EDGES = 2;
// A change this small reads faster as two sentences than as a picture.
export const MIN_RUNTIME_LINES = 20;

// Tests and docs never earn a picture on their own. README.md lists these
// same patterns, so change both together.
const NOT_RUNTIME = [
  /(^|\/)(tests?|__tests__|e2e|spec|testdata|fixtures|docs?)\//i,
  /\.(test|spec)\.[^/]+$/i,
  /_test\.[^/]+$/i,
  /(^|\/)test_[^/]+\.py$/i,
  /\.(md|mdx|rst|adoc)$/i,
];

export const isRuntimeFile = (path) => !NOT_RUNTIME.some((pattern) => pattern.test(path));

const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

// Lines changed in files that run, so a large test or doc update alone never
// earns a picture.
export const runtimeLines = (files) =>
  files
    .filter((file) => isRuntimeFile(file.path))
    .reduce((sum, file) => sum + (file.additions ?? 0) + (file.deletions ?? 0), 0);

// Reads `git diff -z --numstat`. Without -z a rename reads `src/{a => b}.ts`,
// which is no path at all. With -z a rename leaves the path field empty and
// puts the old and the new path in the next two fields. A binary file's line
// counts are `-`, which is not zero.
export const parseNumstat = (stdout) => {
  const fields = stdout.split("\0");
  const files = [];
  const count = (value) => (value === "-" ? undefined : Number(value));
  for (let index = 0; index < fields.length; index += 1) {
    if (fields[index] === "") continue;
    const [additions, deletions, inline] = fields[index].split("\t");
    let path = inline;
    if (path === "") {
      index += 2;
      path = fields[index];
    }
    if (additions === undefined || deletions === undefined || !path) continue;
    files.push({ path, additions: count(additions), deletions: count(deletions) });
  }
  return files;
};

const FENCE = /^```(?:json)?\s*\n([\s\S]*?)\n?```\s*$/;

// Models asked for JSON still fence it now and then, or put a line of prose
// first. A run that already spent the tokens should not fail on packaging.
export const readJsonObject = (text) => {
  const fenced = FENCE.exec(text.trim());
  const candidate = fenced?.[1] ?? text;
  const start = candidate.indexOf("{");
  const end = candidate.lastIndexOf("}");
  let reason = "the answer holds no JSON object";
  for (const attempt of [candidate, start >= 0 && end > start ? candidate.slice(start, end + 1) : ""]) {
    if (attempt === "") continue;
    try {
      const value = JSON.parse(attempt);
      if (isRecord(value)) return { ok: true, value };
      reason = "the answer is JSON, but not an object";
    } catch (error) {
      reason = error instanceof Error ? error.message : String(error);
    }
  }
  return { ok: false, reason };
};

// The repository knows these, so they overwrite whatever the model wrote.
export const applyKnownFields = (body, known) => ({
  ...body,
  schemaVersion: SCHEMA_VERSION,
  kind: "graph",
  generatedAt: known.generatedAt,
  provenance: known.provenance,
  lenses: [...known.lenses],
  stats: { ...(isRecord(body.stats) ? body.stats : {}), ...known.stats },
});

// Models write a payload sample as a JSON string as often as a JSON value.
const decodeSample = (value) => {
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
};

const normalizeSide = (value) =>
  isRecord(value)
    ? {
        ...value,
        ...("sample" in value ? { sample: decodeSample(value.sample) } : {}),
        ...("before" in value ? { before: decodeSample(value.before) } : {}),
      }
    : value;

export const normalizePayloadSamples = (body) => {
  if (!Array.isArray(body.flows)) return body;
  return {
    ...body,
    flows: body.flows.map((flow) => {
      if (!isRecord(flow) || !Array.isArray(flow.messages)) return flow;
      return {
        ...flow,
        messages: flow.messages.map((message) => {
          if (!isRecord(message) || !isRecord(message.payload)) return message;
          const payload = message.payload;
          return {
            ...message,
            payload: {
              ...payload,
              ...("request" in payload ? { request: normalizeSide(payload.request) } : {}),
              ...("response" in payload ? { response: normalizeSide(payload.response) } : {}),
            },
          };
        }),
      };
    }),
  };
};

export const buildUserPrompt = ({ repository, base, head, pullRequest, diff, jsonSchema }) =>
  [
    "The author's pull request title and description follow. Use them to understand intent and to name things, but draw only what the diff shows.",
    `Title: ${pullRequest.title}`,
    "",
    (pullRequest.body ?? "").slice(0, 8000),
    "",
    "---",
    "",
    `Repository: ${repository}`,
    `Base commit: ${base}`,
    `Head commit: ${head}`,
    "Lenses to fill: architecture, data-flow - exactly these, and no others.",
    "",
    `Changed files (${diff.files.length}, +${diff.additions} -${diff.deletions}):`,
    ...diff.files.map(
      (file) =>
        `  ${file.path} (${file.additions === undefined ? "bin" : `+${file.additions}`}${file.deletions === undefined ? "" : ` -${file.deletions}`})`,
    ),
    "",
    "Leave out schemaVersion, kind, generatedAt, provenance, and the numeric fields of stats. Those are filled in from the repository itself, and anything you write there is discarded.",
    "",
    "JSON Schema of the document (draft 2020-12). A field with a default may be omitted:",
    "",
    jsonSchema,
    "",
    "The diff follows.",
    diff.truncatedAt === undefined
      ? ""
      : `It was truncated at ${diff.truncatedAt} bytes, so the tail of the change is missing. Describe what you can see and do not invent the rest.`,
    "",
    diff.patch,
  ].join("\n");

export const buildJsonRepairPrompt = (reason) =>
  [
    `That answer could not be read as JSON: ${reason}`,
    "",
    "Return the whole document again as a single JSON object and nothing else: no prose around it, no markdown fence, and nothing after the closing brace. If the previous answer was cut off, shorten the document so it fits: fewer nodes and one flow beat a document that never ends.",
  ].join("\n");

export const buildRepairPrompt = (message) =>
  [
    "That document was rejected. Each line is one problem, as a path into the document, a reason, and the machine code:",
    "",
    message,
    "",
    "Return the whole corrected document again, as JSON alone. Fix only what was named. Do not restructure the parts that validated, and do not add fields the schema does not name.",
  ].join("\n");

// What the comment shows, decided from the diff and the document, never from
// the model's own judgement. Returns the document to render and why.
//   data-flow    one picture per usable flow, at most MAX_FLOWS
//   architecture one picture, when no flow is usable but the view has substance
//   none         text only
export const chooseDrawing = (document, files) => {
  const lines = runtimeLines(files);
  const flows = document.flows.filter((flow) => flow.messages.length >= MIN_FLOW_STEPS).slice(0, MAX_FLOWS);
  const { walkthrough: _dropped, ...rest } = document;
  const base = { ...rest, views: [] };

  if (lines < MIN_RUNTIME_LINES) {
    return { drawing: "none", reason: "small", runtimeLines: lines, document: base };
  }
  if (flows.length > 0) {
    return {
      drawing: "data-flow",
      reason: "flows",
      runtimeLines: lines,
      document: {
        ...base,
        lenses: ["data-flow"],
        flows,
        views: flows.map((flow, index) => ({
          id: `view-${flow.id}`,
          title: flow.title,
          lens: "data-flow",
          ...(flow.summary === undefined ? {} : { summary: flow.summary }),
          scope: { kind: "selection", flows: [flow.id] },
          defaultOpen: index === 0,
        })),
      },
    };
  }
  if (document.nodes.length >= MIN_ARCHITECTURE_NODES && document.edges.length >= MIN_ARCHITECTURE_EDGES) {
    return {
      drawing: "architecture",
      reason: "architecture",
      runtimeLines: lines,
      document: { ...base, lenses: ["architecture"], flows: [] },
    };
  }
  return { drawing: "none", reason: "nothing-to-draw", runtimeLines: lines, document: base };
};

const escapeHtml = (text) =>
  String(text).replace(/[&<>"]/g, (found) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[found]);

const paragraphs = (text) =>
  String(text)
    .split(/\n+/)
    .map((line) => line.trim())
    .filter((line) => line !== "")
    .map((line) => `<p>${escapeHtml(line)}</p>`);

// A space or a parenthesis in a URL ends it early in some markdown renderers.
const assetUrl = (assetsUrl, path) =>
  `${assetsUrl.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`.replace(
    /[<>() ]/g,
    (found) => `%${found.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`,
  );

const NO_DRAWING_NOTE = {
  small: (lines) => `不算測試和文件，程式碼只改了 ${lines} 行，所以這次只附文字摘要，不畫圖。`,
  "nothing-to-draw": () => "這次的改動沒有可以畫的流程或連線，所以只附文字摘要，不畫圖。",
};

// The comment body below the marker lines, in Chinese. `manifest` and
// `assetsUrl` are absent when nothing was drawn.
export const composeComment = ({ graph, choice, manifest, assetsUrl, branding }) => {
  const stats = graph.stats ?? {};
  const chips = [
    stats.filesChanged === undefined ? undefined : `${stats.filesChanged} 個檔案`,
    stats.additions === undefined ? undefined : `+${stats.additions}`,
    stats.deletions === undefined ? undefined : `−${stats.deletions}`,
    ...(stats.chips ?? []).map((chip) => `${chip.label} ${chip.value}`),
  ].filter((chip) => chip !== undefined);

  const lines = [`<h3>${escapeHtml(graph.title)}</h3>`, ...paragraphs(graph.summary ?? "")];
  if (chips.length > 0) lines.push(`<p>${chips.map((chip) => `<code>${escapeHtml(chip)}</code>`).join(" · ")}</p>`);

  if (choice.drawing === "none") {
    lines.push(`<p><sub>${NO_DRAWING_NOTE[choice.reason](choice.runtimeLines)}</sub></p>`);
  } else {
    const views = new Map((graph.views ?? []).map((view) => [view.id, view]));
    const assets = manifest.assets.filter((asset) => asset.theme === "dark");
    assets.forEach((asset, index) => {
      const view = asset.view === undefined ? undefined : views.get(asset.view);
      const title = view?.title ?? (asset.lens === "architecture" ? "架構" : "流程");
      const url = assetUrl(assetsUrl, asset.path);
      lines.push(
        "",
        `<details${index === 0 ? " open" : ""}>`,
        `<summary><b>${escapeHtml(title)}</b></summary>`,
        "",
        ...(view?.summary === undefined ? [] : paragraphs(view.summary)),
        "",
        `<a href="${url}"><img alt="${escapeHtml(title)}" src="${url}" width="${asset.width}"></a>`,
        "",
        "</details>",
      );
    });
  }

  if (branding) {
    lines.push("", "---", "", '<sub>◈ 由 <a href="https://github.com/coldteadotai/pr-lens">PR Lens</a> 繪製</sub>');
  }
  return `${lines.join("\n")}\n`;
};
