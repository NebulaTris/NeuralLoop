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
