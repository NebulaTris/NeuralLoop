"""Merge per-chapter concept graphs into one book-wide knowledge graph.

The output follows Understand-Anything's KnowledgeGraph shape (kind "knowledge"), with node ids
prefixed by chapter (``c3:caching``) and ``similar_to`` edges joining ideas that share a name
across chapters.
"""

import time

from .convert import plain_words

_ARTICLES = frozenset({"the", "a", "an"})


def normalise_name(name: str) -> str:
    """Casefold, drop punctuation and English articles, collapse spaces; words in any script are kept."""
    return " ".join(word for word in plain_words(name).split() if word not in _ARTICLES)


def build(chapters: list[dict]) -> dict:
    nodes, edges, layers, tour = [], [], [], []
    ids_by_name: dict[str, list[tuple[int, str]]] = {}  # name -> (chapter, node id)
    seen: set[str] = set()  # a graph saved by an older version may repeat a concept id
    for chapter in chapters:
        graph = chapter.get("graph")
        if not graph:
            continue
        prefix = f"c{chapter['n']}:"
        layer_names = {layer["id"]: layer["name"] for layer in graph["layers"]}
        layers.append({"id": f"c{chapter['n']}", "name": f"{chapter['n']}. {chapter['title']}"[:48]})
        for concept in graph["concepts"]:
            node_id = prefix + concept["id"]
            if node_id in seen:
                continue
            seen.add(node_id)
            nodes.append(
                {
                    "id": node_id,
                    "name": concept["name"],
                    "type": concept["type"],
                    "summary": concept["summary"],
                    "detail": concept["detail"],
                    "complexity": concept["complexity"],
                    "chapter": chapter["n"],
                    "layer": concept["layer"],
                    "layerName": layer_names.get(concept["layer"], ""),
                }
            )
            if key := normalise_name(concept["name"]):  # a name with no words matches nothing
                ids_by_name.setdefault(key, []).append((chapter["n"], node_id))
        edges.extend(
            {
                "source": prefix + e["source"],
                "target": prefix + e["target"],
                "type": e["type"],
                "description": e.get("description", ""),
            }
            for e in graph["edges"]
        )
        if graph["tour"]:
            first = graph["tour"][0]
            tour.append(
                {
                    "title": f"Chapter {chapter['n']}: {first['title']}",
                    "description": first.get("description", ""),
                    "nodeIds": [prefix + i for i in first["nodeIds"]],
                }
            )
    for same in ids_by_name.values():
        firsts: dict[int, str] = {}  # one node per chapter: a name repeated inside a chapter links to nothing
        for chapter_n, node_id in same:
            firsts.setdefault(chapter_n, node_id)
        first, *others = firsts.values()
        edges.extend(
            {
                "source": other,
                "target": first,
                "type": "similar_to",
                "description": "same idea in another chapter",
            }
            for other in others
        )
    return {
        "version": "1.0.0",
        "kind": "knowledge",
        "project": {
            "name": "NeuralLoop book map",
            "languages": [],
            "frameworks": [],
            "description": "",
            "analyzedAt": time.strftime("%Y-%m-%d"),
            "gitCommitHash": "",
        },
        "nodes": nodes,
        "edges": edges,
        "layers": layers,
        "tour": tour,
    }
