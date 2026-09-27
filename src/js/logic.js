// Decisions the desktop screens make, kept free of the DOM so they can be unit-tested.

const MEDIA_SPEC = /^(all|none|\d+(-\d+)?(,\d+(-\d+)?)*)$/;

/** "1-2", "1,4,7", "all", or "none". */
export function isValidMediaSpec(spec) {
  return MEDIA_SPEC.test(spec.trim());
}

/** What Pip says on the library screen, and in which pose. */
export function pipGreeting(books) {
  const due = books.reduce((sum, book) => sum + (book.due || 0), 0);
  const preparing = books.find((book) => book.running);
  if (preparing) return { pose: "study", line: `I'm preparing “${preparing.title}”. You can start on ready chapters any time.` };
  if (due) {
    const minutes = Math.max(1, Math.ceil((due * 15) / 60));
    return { pose: "play", line: `${due} card${due > 1 ? "s are" : " is"} ready. About ${minutes} min, then we're done.` };
  }
  if (!books.length) return { pose: "hop", line: "Hi, I'm Pip! Give me a book and I'll turn it into little learning loops." };
  return { pose: "read", line: "All caught up. Maybe a walk? Rest helps memories set." };
}

/** Labelled pills for a book card, from its status counts. */
export function statusPills(book) {
  const counts = book.counts || {};
  const pills = [];
  if (book.running) pills.push({ kind: "work", text: "Preparing", spinner: true });
  if (counts.done) pills.push({ kind: "done", text: `${counts.done} ready` });
  if (counts.waiting_quota) pills.push({ kind: "wait", text: `${counts.waiting_quota} waiting for NotebookLM's limit` });
  if (counts.failed) pills.push({ kind: "fail", text: `${counts.failed} couldn't be made` });
  if (book.due) pills.push({ kind: "plain", text: `${book.due} cards due` });
  return pills;
}

/** Setup checklist rows; empty when everything is ready. */
export function setupSteps(setup) {
  if (!setup) return [];
  const steps = [
    {
      ok: Boolean(setup.python),
      done: `Python 3.10+ found (${setup.python})`,
      todo: "Install Python 3.12 from python.org, then click Check again",
    },
    {
      ok: Boolean(setup.notebooklm),
      done: `NotebookLM library ${setup.notebooklm}`,
      todo: 'Install the NotebookLM library: pip install "notebooklm-py[browser]" pypdf',
    },
    { ok: Boolean(setup.pypdf), done: "PDF support", todo: "Install PDF support: pip install pypdf" },
    { ok: Boolean(setup.signedIn), done: "Signed in to NotebookLM", todo: "Sign in once: notebooklm login" },
  ];
  return steps.every((step) => step.ok) ? [] : steps;
}

/** Backend errors arrive as "code: message"; show only the message. */
export function friendlyError(error) {
  return String(error?.message || error).replace(/^[a-z_]+: /, "");
}
