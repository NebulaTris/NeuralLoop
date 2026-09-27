from neuralloop_books import convert


class TestLooseJson:
    def test_plain_json(self):
        assert convert.loose_json('{"a": 1}') == {"a": 1}

    def test_code_fence_and_prose(self):
        assert convert.loose_json('Sure! Here it is:\n```json\n{"a": 2}\n```\nHope that helps.') == {"a": 2}

    def test_citation_markers_are_removed(self):
        assert convert.loose_json('{"a": "x" [1], "b": "y" [2, 3]}') == {"a": "x", "b": "y"}

    def test_json_embedded_in_prose_without_fence(self):
        assert convert.loose_json('The graph: {"a": 3} as requested') == {"a": 3}

    def test_garbage_returns_none(self):
        assert convert.loose_json("no json here") is None
        assert convert.loose_json(None) is None


def test_quiz_keeps_only_complete_questions():
    data = {
        "questions": [
            {
                "question": "Q1",
                "answerOptions": [{"text": "a", "isCorrect": True, "rationale": "yes"}, {"text": "b"}],
                "hint": "h",
            },
            {"question": "No correct answer", "answerOptions": [{"text": "a"}, {"text": "b"}]},
            {"question": "Too few options", "answerOptions": [{"text": "a", "isCorrect": True}]},
        ]
    }
    assert convert.quiz(data) == [{"q": "Q1", "options": ["a", "b"], "a": 0, "hint": "h", "why": ["yes", ""]}]


def test_quiz_with_wrong_shape_is_empty():
    assert convert.quiz(None) == []
    assert convert.quiz({"questions": "nope"}) == []


def test_flashcards_drop_blank_cards():
    data = {"cards": [{"front": "F", "back": "B"}, {"front": "", "back": "B"}, "junk"]}
    assert convert.flashcards(data) == [{"front": "F", "back": "B"}]


def test_study_normalises_levels_and_limits_prompts():
    data = {
        "guide": [{"section": "Intro", "level": "urgent", "why": "w"}, {"level": "deep"}],
        "recall": [{"prompt": f"P{i}", "keyPoints": ["k"]} for i in range(6)] + [{"prompt": "no points"}],
    }
    result = convert.study(data)
    assert result["guide"] == [{"section": "Intro", "level": "normal", "why": "w"}]
    assert [r["prompt"] for r in result["recall"]] == ["P0", "P1", "P2", "P3"]


def test_study_with_nothing_usable_is_none():
    assert convert.study({"guide": [], "recall": []}) is None
    assert convert.study([]) is None


def test_concept_graph_removes_dangling_references_and_fills_defaults():
    data = {
        "concepts": [
            {"id": "a", "name": "A", "layer": "missing"},
            {"id": "b", "name": "B"},
            {"name": "no id"},
        ],
        "layers": [{"id": "l1", "name": "Layer"}],
        "edges": [
            {"source": "a", "target": "b"},
            {"source": "a", "target": "zzz"},
            {"source": "a", "target": "a"},
        ],
        "tour": [{"title": "T", "nodeIds": ["a", "zzz"]}, {"title": "empty", "nodeIds": ["zzz"]}],
    }
    g = convert.concept_graph(data)
    assert [c["id"] for c in g["concepts"]] == ["a", "b"]
    assert g["concepts"][0]["layer"] == "l1" and g["concepts"][0]["complexity"] == "moderate"
    assert g["edges"] == [{"source": "a", "target": "b"}]
    assert g["tour"] == [{"title": "T", "nodeIds": ["a"]}]


def test_concept_graph_without_concepts_is_none():
    assert convert.concept_graph({"concepts": []}) is None
