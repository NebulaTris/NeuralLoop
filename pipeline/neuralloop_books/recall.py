"""Checking a free-recall answer: which key points it covers, plus short, kind feedback.

A small local model (gemma2:2b by default) judges meaning, not exact words, one key point at a time (small
models can't keep several verdicts lined up), all in parallel. A verdict counts only when its quoted evidence
is in the answer and is about that idea. If the model is offline or keeps slipping, word matching answers,
so the Recall step never gets stuck.
"""

import asyncio
import re

from . import convert, prompts
from .schemas import SCHEMAS

ATTEMPTS = 2

_WORD = re.compile(r"[a-z0-9']+")
_STOP = {
    "that",
    "this",
    "with",
    "from",
    "have",
    "they",
    "their",
    "what",
    "when",
    "your",
    "into",
    "than",
    "then",
}
# Words a grader uses to describe evidence rather than quote it.
_META = {
    "answer",
    "learner",
    "clearly",
    "expresses",
    "mentions",
    "states",
    "says",
    "explains",
    "idea",
    "point",
}
EMPTY_FEEDBACK = (
    "Write whatever you remember, even a sentence. Every bit you pull from memory helps it stick."
)


def _stems(text: str) -> set[str]:
    return {w[:5] for w in _WORD.findall(text.lower()) if len(w) > 3 and w not in _STOP}


def word_match(key_points: list[str], answer: str) -> list[bool]:
    """A key point counts as covered when most of its meaningful words (by stem) appear in the answer."""
    said = _stems(answer)
    covered = []
    for point in key_points:
        words = _stems(point)
        covered.append(bool(words) and len(words & said) / len(words) >= 0.6)
    return covered


def _grounded(quote: str, answer: str, idea: str) -> bool:
    """Evidence must mostly come from the answer (0.4 allows light paraphrase) and touch the idea itself."""
    words = _stems(quote) - {w[:5] for w in _META}
    if not words:
        return False
    in_answer = len(words & _stems(answer)) / len(words) >= 0.4
    return in_answer and bool(words & _stems(idea))


def _result(covered: list[bool], feedback: str, missing: list[str], by: str) -> dict:
    score = sum(covered) / len(covered) if covered else 0.0
    return {"covered": covered, "score": score, "feedback": feedback, "missing": missing, "by": by}


def _plain_feedback(key_points: list[str], covered: list[bool]) -> tuple[str, list[str]]:
    missing = [p for p, ok in zip(key_points, covered, strict=True) if not ok]
    remembered = [p for p, ok in zip(key_points, covered, strict=True) if ok]
    if not missing:
        return "You covered every key point. Lovely recall!", []
    if remembered:
        return f"Nice: you remembered that {remembered[0]}. Next time, also add that {missing[0]}.", missing
    return f"Good start. Next time, try to include that {missing[0]}.", missing


async def grade(model, question: str, key_points: list[str], answer: str) -> dict:
    if not answer.strip():
        return _result([False] * len(key_points), EMPTY_FEEDBACK, list(key_points), "Pip")
    verdicts = await asyncio.gather(*(_check(model, question, point, answer) for point in key_points))
    if all(v is None for v in verdicts):
        covered, by = word_match(key_points, answer), "word match"
    else:
        # An idea the model couldn't judge falls back to word matching; the rest are the model's.
        fallback = word_match(key_points, answer)
        covered = [fallback[i] if v is None else v for i, v in enumerate(verdicts)]
        by = model.name
    feedback, missing = _plain_feedback(key_points, covered)
    return _result(covered, feedback, missing, by)


async def _check(model, question: str, point: str, answer: str) -> bool | None:
    """True/False for one key point, or None when the model can't give a usable verdict."""
    ask = prompts.RECALL_POINT.format(question=question, point=point, answer=answer.strip())
    for _ in range(ATTEMPTS):
        try:
            reply = await model.complete("recall", prompts.RECALL_SYSTEM, "", ask, schema=SCHEMAS["recall"])
        except Exception:  # offline or broken grader: word matching still gives a fair result
            return None
        verdict = convert.recall_verdict(convert.loose_json(reply))
        if verdict is not None:
            covered, evidence = verdict
            return covered and _grounded(evidence, answer, point)
    return None
