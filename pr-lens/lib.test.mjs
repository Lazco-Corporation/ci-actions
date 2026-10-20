// Run after `pr-lens.sh install`, from the install directory:
//   node --test "$RUNNER_TEMP/pr-lens-cli/lib.test.mjs"
import assert from "node:assert/strict";
import { test } from "node:test";
import { SCHEMA_VERSION, safeParseGraphDoc } from "@coldtea/pr-lens-schema";
import { chooseDrawing, composeComment, readJsonObject, runtimeLines } from "./lib.mjs";

const message = (id, from, to) => ({ id, from, to, label: "呼叫", kind: "sync", delta: "added" });

const flow = (id, steps) => ({
  id,
  title: `流程 ${id}`,
  summary: `流程 ${id} 的說明`,
  participants: [{ node: "api" }, { node: "db" }],
  messages: Array.from({ length: steps }, (_, index) => message(`${id}-${index}`, "api", "db")),
});

const documentWith = ({ flows = [], nodes = 2, edges = 0 } = {}) => {
  const nodeIds = ["api", "db", "worker", "queue"].slice(0, nodes);
  return {
    schemaVersion: SCHEMA_VERSION,
    kind: "graph",
    id: "fixture",
    generatedAt: "2026-01-01T00:00:00.000Z",
    title: "測試標題",
    summary: "第一句。\n改之前：A。\n改之後：B。",
    lenses: ["architecture", "data-flow"],
    provenance: {
      repo: { owner: "owner", name: "repo", host: "github.com" },
      base: { sha: "a".repeat(40) },
      head: { sha: "b".repeat(40) },
      generator: { name: "test", version: "1" },
    },
    lanes: [{ id: "server", label: "伺服器" }],
    nodes: nodeIds.map((id) => ({ id, label: id, kind: "service", delta: "modified", lane: "server" })),
    edges: Array.from({ length: edges }, (_, index) => ({
      id: `edge-${index}`,
      from: nodeIds[index % nodeIds.length],
      to: nodeIds[(index + 1) % nodeIds.length],
      kind: "call",
      delta: "added",
    })),
    flows,
    stats: { filesChanged: 3, additions: 40, deletions: 2, chips: [{ label: "重試", value: "3 次" }] },
    walkthrough: { steps: [] },
  };
};

const bigChange = [{ path: "src/server.ts", additions: 30, deletions: 5 }];

test("runtime lines leave out tests and docs", () => {
  const files = [
    { path: "src/a.ts", additions: 5, deletions: 2 },
    { path: "src/a.test.ts", additions: 100, deletions: 0 },
    { path: "tests/e2e.ts", additions: 50, deletions: 0 },
    { path: "docs/guide.txt", additions: 9, deletions: 0 },
    { path: "README.md", additions: 9, deletions: 0 },
    { path: "logo.png", additions: undefined, deletions: undefined },
  ];
  assert.equal(runtimeLines(files), 7);
});

test("a small change is drawn as text only, even with a good flow", () => {
  const choice = chooseDrawing(documentWith({ flows: [flow("one", 5)] }), [{ path: "src/a.ts", additions: 3, deletions: 4 }]);
  assert.equal(choice.drawing, "none");
  assert.equal(choice.reason, "small");
  assert.equal(choice.runtimeLines, 7);
});

test("usable flows become one view each, at most two, and the walkthrough goes", () => {
  const choice = chooseDrawing(
    documentWith({ flows: [flow("one", 4), flow("short", 2), flow("two", 3), flow("three", 5)] }),
    bigChange,
  );
  assert.equal(choice.drawing, "data-flow");
  assert.deepEqual(
    choice.document.flows.map((kept) => kept.id),
    ["one", "two"],
  );
  assert.deepEqual(
    choice.document.views.map((view) => [view.id, view.defaultOpen]),
    [
      ["view-one", true],
      ["view-two", false],
    ],
  );
  assert.deepEqual(choice.document.lenses, ["data-flow"]);
  assert.equal("walkthrough" in choice.document, false);
  const checked = safeParseGraphDoc(choice.document);
  assert.ok(checked.ok, checked.ok ? "" : checked.error.message);
});

test("no usable flow falls back to architecture when it has substance", () => {
  const choice = chooseDrawing(documentWith({ flows: [flow("short", 2)], nodes: 3, edges: 2 }), bigChange);
  assert.equal(choice.drawing, "architecture");
  assert.deepEqual(choice.document.lenses, ["architecture"]);
  assert.deepEqual(choice.document.flows, []);
  const checked = safeParseGraphDoc(choice.document);
  assert.ok(checked.ok, checked.ok ? "" : checked.error.message);
});

test("a thin architecture view is text only", () => {
  const choice = chooseDrawing(documentWith({ nodes: 2, edges: 1 }), bigChange);
  assert.equal(choice.drawing, "none");
  assert.equal(choice.reason, "nothing-to-draw");
});

test("the comment for a text-only change says why, in Chinese, with no image", () => {
  const graph = documentWith();
  const body = composeComment({
    graph,
    choice: { drawing: "none", reason: "small", runtimeLines: 7 },
    branding: true,
  });
  assert.match(body, /<h3>測試標題<\/h3>/);
  assert.match(body, /<p>改之前：A。<\/p>/);
  assert.match(body, /<code>3 個檔案<\/code>/);
  assert.match(body, /<code>重試 3 次<\/code>/);
  assert.match(body, /程式碼只改了 7 行/);
  assert.match(body, /由 <a href="https:\/\/github.com\/coldteadotai\/pr-lens">PR Lens<\/a> 繪製/);
  assert.doesNotMatch(body, /<img/);
  assert.doesNotMatch(body, /\bfiles?\b|Rendered by/);
});

test("the comment draws each flow in its own section, the first open", () => {
  const choice = chooseDrawing(documentWith({ flows: [flow("one", 4), flow("two", 3)] }), bigChange);
  const manifest = {
    assets: [
      { view: "view-one", lens: "data-flow", theme: "dark", path: "one dark.svg", width: 1200 },
      { view: "view-two", lens: "data-flow", theme: "dark", path: "two.svg", width: 900 },
    ],
  };
  const body = composeComment({
    graph: choice.document,
    choice,
    manifest,
    assetsUrl: "https://example.test/raw/pr-lens/pr/1/abc/",
    branding: false,
  });
  assert.equal(body.match(/<details/g).length, 2);
  assert.match(body, /<details open>\n<summary><b>流程 one<\/b><\/summary>/);
  assert.match(body, /<details>\n<summary><b>流程 two<\/b><\/summary>/);
  assert.match(body, /src="https:\/\/example.test\/raw\/pr-lens\/pr\/1\/abc\/one%20dark.svg" width="1200"/);
  assert.doesNotMatch(body, /PR Lens/);
});

test("the comment escapes HTML the model wrote", () => {
  const graph = { ...documentWith(), title: "<script>x</script>", summary: 'a "b" & c' };
  const body = composeComment({ graph, choice: { drawing: "none", reason: "nothing-to-draw" }, branding: false });
  assert.match(body, /&lt;script&gt;x&lt;\/script&gt;/);
  assert.match(body, /a &quot;b&quot; &amp; c/);
});

test("a fenced JSON answer is still read", () => {
  const read = readJsonObject('```json\n{"title": "x"}\n```');
  assert.deepEqual(read, { ok: true, value: { title: "x" } });
  assert.equal(readJsonObject("no json here").ok, false);
});
