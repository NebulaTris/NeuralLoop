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
    assert g["edges"] == [{"source": "a", "target": "b", "type": "related", "description": ""}]
    assert g["tour"] == [{"title": "T", "description": "", "nodeIds": ["a"]}]


def test_concept_graph_without_concepts_is_none():
    assert convert.concept_graph({"concepts": []}) is None


def test_mind_map_drops_empty_names_and_caps_depth():
    deep = {"name": "L3", "children": [{"name": "L4", "children": [{"name": "L5"}]}]}
    data = {
        "name": "Root",
        "children": [{"name": ""}, {"name": "L1", "children": [{"name": "L2", "children": [deep]}]}],
    }
    tree = convert.mind_map(data)
    assert [c["name"] for c in tree["children"]] == ["L1"]
    level3 = tree["children"][0]["children"][0]["children"][0]
    assert level3["name"] == "L3" and "children" not in level3


def test_mind_map_needs_a_named_root():
    assert convert.mind_map({"children": [{"name": "x"}]}) is None
    assert convert.mind_map(["not", "a", "tree"]) is None


def test_podcast_script_needs_both_speakers_and_text():
    data = {
        "title": "Caching",
        "lines": [
            {"speaker": "A", "text": "Welcome back!", "delivery": "excited"},
            {"speaker": "b", "text": "  "},
            {"speaker": "B", "text": "Let's talk caches."},
            {"speaker": "C", "text": "Who am I?"},
        ],
    }
    script = convert.podcast_script(data)
    assert script["title"] == "Caching"
    assert [(line["speaker"], line["text"]) for line in script["lines"]] == [
        ("A", "Welcome back!"),
        ("B", "Let's talk caches."),
    ]
    assert script["lines"][1]["delivery"] == ""
    assert convert.podcast_script({"lines": [{"speaker": "A", "text": "Just me"}]}) is None


def test_explainer_caps_slides_and_defaults_unknown_poses():
    slides = [
        {"title": f"S{i}", "points": ["a", "", "b"], "narration": "Say this.", "pose": "moonwalk"}
        for i in range(12)
    ]
    slides.append({"title": "No narration", "points": []})
    result = convert.explainer({"slides": slides})
    assert len(result["slides"]) == 8
    assert result["slides"][0] == {
        "title": "S0",
        "points": ["a", "b"],
        "narration": "Say this.",
        "pose": "read",
    }
    assert convert.explainer({"slides": []}) is None


def test_loose_json_rescues_curly_quotes_that_close_strings():
    broken = '{"cards":[{"front":"What is a snapshot?", "back":"A system frozen in time.”}]}'
    assert convert.loose_json(broken) == {
        "cards": [{"front": "What is a snapshot?", "back": "A system frozen in time."}]
    }
    assert convert.loose_json('{"quote": "She said “hi”."}') == {"quote": "She said “hi”."}


def test_mind_map_drops_repeated_branches_and_echoes_of_the_parent():
    branch = {
        "name": "Systems Fail",
        "children": [{"name": "Drift"}, {"name": "drift"}, {"name": "Systems fail"}],
    }
    tree = convert.mind_map(
        {"name": "Why Systems Fail", "children": [branch, dict(branch), {"name": "Why systems fail"}]}
    )
    assert [c["name"] for c in tree["children"]] == ["Systems Fail"]
    assert [c["name"] for c in tree["children"][0]["children"]] == ["Drift"]


def test_a_concept_graph_can_be_grown_from_the_mind_map():
    tree = {
        "name": "Why Systems Fail",
        "children": [
            {
                "name": "World keeps moving",
                "children": [{"name": "Reality drifts"}, {"name": "Snapshots age"}],
            },
            {"name": "Monitoring", "children": [{"name": "Catch drift early"}]},
        ],
    }
    graph = convert.graph_from_mind_map(tree)
    assert convert.concept_graph(graph) is not None  # the same check a model's graph must pass
    names = {c["name"] for c in graph["concepts"]}
    assert {"World keeps moving", "Reality drifts", "Catch drift early"} <= names
    assert {e["type"] for e in graph["edges"]} == {"categorized_under"}
    assert len(graph["layers"]) == 2 and graph["tour"][0]["nodeIds"]


def test_odd_model_values_become_plain_text_and_never_break_the_book_map():
    """A model (or a book talking to it) can answer with any JSON; book.json and the book map still build."""
    from neuralloop_books import book_graph

    data = {
        "concepts": [
            {"id": ["a"], "name": "Unhashable id"},
            {"id": "b", "name": {"x": 1}},
            {"id": 7, "name": "Seven", "summary": ["not", "text"], "layer": None, "__proto__": {"x": 1}},
            {"id": "c", "name": "C"},
        ],
        "layers": [{"id": {"no": 1}}, {"id": "l1"}],
        "edges": [{"source": "7", "target": "c"}, {"source": ["7"], "target": "c"}],
        "tour": [{"nodeIds": "c"}, {"title": 3, "nodeIds": [7, None]}],
    }
    g = convert.concept_graph(data)
    assert [c["id"] for c in g["concepts"]] == ["7", "c"]
    assert set(g["concepts"][0]) == {"id", "name", "type", "summary", "detail", "complexity", "layer"}
    assert g["concepts"][0]["summary"] == "" and g["layers"] == [{"id": "l1", "name": "l1"}]
    assert g["edges"] == [{"source": "7", "target": "c", "type": "related", "description": ""}]
    assert g["tour"] == [{"title": "3", "description": "", "nodeIds": ["7"]}]
    book_graph.build([{"n": 1, "title": "One", "graph": g}])  # no KeyError or TypeError


def test_quiz_and_cards_keep_only_text():
    quiz = convert.quiz(
        {
            "questions": [
                {"question": {"x": 1}, "answerOptions": [{"text": "a", "isCorrect": True}, {"text": "b"}]},
                {"question": "Q", "answerOptions": [{"text": "a", "isCorrect": "false"}, {"text": "b"}]},
                {
                    "question": "Q",
                    "hint": ["h"],
                    "answerOptions": [{"text": 1, "isCorrect": True}, {"text": "b"}],
                },
            ]
        }
    )
    assert quiz == [{"q": "Q", "options": ["1", "b"], "a": 0, "hint": "", "why": ["", ""]}]
    assert convert.flashcards({"cards": [{"front": ["x"], "back": "y"}, {"front": "f", "back": "b"}]}) == [
        {"front": "f", "back": "b"}
    ]


def test_a_list_field_given_as_one_string_is_one_item_never_letters():
    study = convert.study({"recall": [{"prompt": "Why cache?", "keyPoints": "Speed matters"}]})
    assert study["recall"][0]["keyPoints"] == ["Speed matters"]
    slides = convert.explainer({"slides": [{"title": "T", "narration": "N", "points": "One idea"}]})
    assert slides["slides"][0]["points"] == ["One idea"]
    odd = convert.study({"recall": [{"prompt": "Why?", "keyPoints": {"a": 1}}]})
    assert odd is None or not odd["recall"]


def test_a_concept_graph_keeps_the_first_of_repeated_ids():
    graph = convert.concept_graph(
        {
            "concepts": [
                {"id": "cache", "name": "Caching"},
                {"id": "cache", "name": "Cache again"},
                {"id": "queue", "name": "Queues"},
            ],
            "edges": [
                {"source": "queue", "target": "cache"},
                {"source": "queue", "target": "ghost"},
            ],
        }
    )
    assert [c["name"] for c in graph["concepts"]] == ["Caching", "Queues"]
    assert [(e["source"], e["target"]) for e in graph["edges"]] == [("queue", "cache")]
