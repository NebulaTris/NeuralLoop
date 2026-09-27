import assert from "node:assert/strict";
import { test } from "node:test";

import { friendlyError, isValidMediaSpec, pipGreeting, setupSteps, statusPills } from "../js/logic.js";

test("media specs", () => {
  for (const good of ["1-2", "1,4,7", "all", "none", " 3 "]) assert.ok(isValidMediaSpec(good), good);
  for (const bad of ["1-", "a", "1,,2", ""]) assert.ok(!isValidMediaSpec(bad), bad);
});

test("Pip greets by priority: preparing, then due cards, then empty shelf", () => {
  assert.equal(pipGreeting([{ title: "DDIA", running: true, due: 5 }]).pose, "study");
  assert.match(pipGreeting([{ due: 5 }]).line, /5 cards are ready. About 2 min/);
  assert.equal(pipGreeting([]).pose, "hop");
  assert.equal(pipGreeting([{ due: 0 }]).pose, "read");
});

test("status pills", () => {
  const pills = statusPills({ running: true, due: 2, counts: { done: 9, waiting_quota: 2 } });
  assert.deepEqual(
    pills.map((p) => p.kind),
    ["work", "done", "wait", "plain"],
  );
});

test("setup checklist disappears when everything is ready", () => {
  assert.equal(setupSteps({ python: "/p", notebooklm: "0.8.3", pypdf: "5", signedIn: true }).length, 0);
  assert.deepEqual(
    setupSteps({ python: "/p", notebooklm: null, pypdf: "5", signedIn: false }).map((s) => s.ok),
    [true, false, true, false],
  );
});

test("backend error codes are hidden from people", () => {
  assert.equal(friendlyError("setup: Python 3.10+ wasn't found."), "Python 3.10+ wasn't found.");
});
