from neuralloop_books import book_graph


def chapter(n, concepts, edges=(), tour=()):
    return {
        "n": n,
        "title": f"Chapter {n}",
        "graph": {
            "concepts": [
                {
                    "id": cid,
                    "name": name,
                    "type": "concept",
                    "summary": "",
                    "detail": "",
                    "complexity": "simple",
                    "layer": "l",
                }
                for cid, name in concepts
            ],
            "layers": [{"id": "l", "name": "Layer"}],
            "edges": list(edges),
            "tour": list(tour),
        },
    }


def test_normalise_name():
    assert book_graph.normalise_name("The  Cache-Aside Pattern!") == "cache aside pattern"


def test_ids_are_prefixed_by_chapter_and_edges_follow():
    g = book_graph.build(
        [chapter(1, [("a", "A"), ("b", "B")], edges=[{"source": "b", "target": "a", "type": "builds_on"}])]
    )
    assert [n["id"] for n in g["nodes"]] == ["c1:a", "c1:b"]
    assert g["edges"][0]["source"] == "c1:b" and g["edges"][0]["target"] == "c1:a"
    assert g["kind"] == "knowledge"


def test_same_idea_in_two_chapters_is_linked():
    g = book_graph.build([chapter(1, [("x", "Monitoring")]), chapter(2, [("y", "monitoring")])])
    assert {
        "source": "c2:y",
        "target": "c1:x",
        "type": "similar_to",
        "description": "same idea in another chapter",
    } in g["edges"]


def test_chapters_without_graph_are_skipped():
    assert book_graph.build([{"n": 1, "title": "t"}])["nodes"] == []


def test_the_book_map_never_repeats_a_node_id():
    """A graph saved by an older version may repeat a concept id."""
    concept = {
        "id": "cache",
        "name": "Caching",
        "type": "concept",
        "summary": "",
        "detail": "",
        "complexity": "simple",
        "layer": "core",
    }
    graph = {
        "concepts": [concept, {**concept, "name": "Cache again"}],
        "layers": [{"id": "core", "name": "Core"}],
        "edges": [],
        "tour": [],
    }
    built = book_graph.build([{"n": 1, "title": "One", "graph": graph}])
    ids = [node["id"] for node in built["nodes"]]
    assert ids == ["c1:cache"]


def test_names_in_any_script_normalise_to_their_words():
    assert book_graph.normalise_name("缓存 策略") == "缓存 策略"
    assert book_graph.normalise_name("हिन्दी कहानी!") == "हिन्दी कहानी"  # vowel signs and viramas stay
    assert book_graph.normalise_name("Кэш—Стратегия") == "кэш стратегия"
    assert book_graph.normalise_name("Straße") == book_graph.normalise_name("STRASSE")


def test_only_the_same_idea_is_linked_across_chapters_whatever_the_script():
    g = book_graph.build(
        [
            chapter(1, [("a", "缓存"), ("b", "Очередь")]),
            chapter(2, [("x", "缓存"), ("y", "हिन्दी"), ("z", "Журнал")]),
            chapter(3, [("q", "!!!"), ("r", "?")]),
        ]
    )
    similar = [(e["source"], e["target"]) for e in g["edges"] if e["type"] == "similar_to"]
    assert similar == [("c2:x", "c1:a")]  # names with no words at all link to nothing
