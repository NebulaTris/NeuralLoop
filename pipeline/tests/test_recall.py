import asyncio
import json

from neuralloop_books import recall
from neuralloop_books.models.fake import FakeModel

QUESTION = "Why do systems fail over time?"
POINTS = ["the world keeps changing", "software is a snapshot", "you need monitoring"]


def grade(model, answer):
    return asyncio.run(recall.grade(model, QUESTION, POINTS, answer))


def test_the_model_marks_each_key_point_and_writes_kind_feedback():
    result = grade(FakeModel(), "The world keeps changing but software is a frozen snapshot.")
    assert result["covered"] == [True, True, False]
    assert result["score"] == 2 / 3 and result["feedback"] and result["by"] == "Pip's practice brain"


class BrokenModel(FakeModel):
    async def complete(self, kind, system, source, prompt, schema=None):
        return "no json today"


def test_an_unusable_grader_falls_back_to_word_matching():
    result = grade(BrokenModel(), "Software is a snapshot and you need monitoring.")
    assert result["covered"] == [False, True, True] and result["by"] == "word match"


class OfflineModel(FakeModel):
    async def complete(self, kind, system, source, prompt, schema=None):
        raise OSError("Ollama isn't running")


def test_an_offline_grader_still_gives_a_result():
    assert grade(OfflineModel(), "the world keeps changing")["covered"][0] is True


def test_an_empty_answer_covers_nothing_and_never_calls_the_model():
    model = FakeModel()
    result = grade(model, "   ")
    assert result["covered"] == [False, False, False] and model.calls == []
    assert "Pip" not in result["feedback"] or "sad" not in result["feedback"]


def test_cli_grades_from_stdin(monkeypatch, capsys):
    import io

    from neuralloop_books import cli

    monkeypatch.setattr(
        "sys.stdin",
        io.StringIO(
            json.dumps({"question": QUESTION, "keyPoints": POINTS, "answer": "software is a snapshot"})
        ),
    )
    assert cli.main(["--grade-recall", "--provider", "fake"]) == 0
    printed = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert printed["covered"][1] is True


class OverGenerousModel(FakeModel):
    """Says yes to every idea, quoting words that aren't in the answer or aren't about the idea."""

    async def complete(self, kind, system, source, prompt, schema=None):
        idea = prompt.split('Idea: "')[1].split('"')[0]
        evidence = idea if "monitoring" not in idea else "The world keeps changing"
        return json.dumps({"covered": True, "evidence": evidence})


def test_a_point_only_counts_when_its_evidence_is_in_the_answer_and_about_the_idea():
    result = grade(OverGenerousModel(), "The world keeps changing but software is a frozen snapshot.")
    assert result["covered"] == [True, True, False]
    assert "monitoring" in result["feedback"]


class FlakyGrader(FakeModel):
    """Unusable the first time for each idea, fine the second; records the schema it was given."""

    def __init__(self):
        super().__init__()
        self.schemas, self.seen = [], set()

    async def complete(self, kind, system, source, prompt, schema=None):
        self.schemas.append(schema)
        if prompt not in self.seen:
            self.seen.add(prompt)
            return "not json"
        return await super().complete(kind, system, source, prompt)


def test_each_idea_is_checked_separately_and_a_bad_verdict_is_retried():
    model = FlakyGrader()
    result = grade(model, "The world keeps changing but software is a frozen snapshot.")
    assert result["by"] == "Pip's practice brain" and result["covered"] == [True, True, False]
    assert len(model.schemas) == 6 and set(model.schemas[0]["properties"]) == {"covered", "evidence"}


def test_feedback_is_warm_and_names_the_next_thing_to_add():
    result = grade(FakeModel(), "The world keeps changing.")
    assert result["feedback"].startswith("Nice") and "software is a snapshot" in result["feedback"]
    everything = grade(
        FakeModel(), "The world keeps changing, software is a snapshot, and you need monitoring."
    )
    assert everything["covered"] == [True, True, True] and "every key point" in everything["feedback"]


class TrustingGrader(FakeModel):
    """Says every idea is covered and quotes the whole answer as its evidence."""

    async def complete(self, kind, system, source, prompt, schema=None):
        answer = prompt.split("<<<", 1)[1].split(">>>", 1)[0]
        return json.dumps({"covered": True, "evidence": answer})


def test_word_matching_keeps_english_behaviour():
    answer = "Software is a snapshot and you need monitoring."
    assert recall.word_match(POINTS, answer) == [False, True, True]
    assert recall.word_match(["this with that"], "this with that") == [False]  # only stop words


def test_word_matching_reads_hindi():
    points = ["दुनिया हमेशा बदलती रहती है", "सॉफ़्टवेयर एक तस्वीर है"]
    assert recall.word_match(points, "दुनिया हमेशा बदलती रहती है") == [True, False]


def test_word_matching_reads_accented_latin_words_whole():
    points = ["a résumé at the café", "naïve caching"]
    assert recall.word_match(points, "I left my résumé at the café") == [True, False]
    assert recall.word_match(points, "a resume at the cafe") == [True, False]  # accents are optional
    assert recall.word_match(["naïve"], "so naïve") == [True]  # one word, not "na" and "ve"


def test_word_matching_reads_scripts_without_spaces():
    points = ["缓存提高速度", "数据库需要索引"]
    assert recall.word_match(points, "缓存可以提高速度") == [True, False]
    assert recall.word_match(["ระบบแคชช่วยให้เร็วขึ้น"], "ระบบแคชช่วยให้เร็วขึ้นมาก") == [True]


def test_a_model_verdict_in_hindi_or_chinese_stands_when_its_evidence_is_in_the_answer():
    for point in ("दुनिया हमेशा बदलती रहती है", "缓存提高速度"):
        result = asyncio.run(recall.grade(TrustingGrader(), "?", [point], point))
        assert result["covered"] == [True]
