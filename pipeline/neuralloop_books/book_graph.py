"""Merge per-chapter concept graphs into one book-wide knowledge graph.

The output follows Understand-Anything's KnowledgeGraph shape (kind "knowledge"), with node ids
prefixed by chapter (``c3:caching``) and ``similar_to`` edges joining ideas that share a name
across chapters.
"""

import re
import time

_ARTICLES = re.compile(r"\b(the|a|an)\b")


def normalise_name(name: str) -> str:
    """Lowercase, drop punctuation and articles, collapse spaces."""
    text = re.sub(r"[^a-z0-9]+", " ", str(name).lower())
    return re.sub(r"\s+", " ", _ARTICLES.sub(" ", text)).strip()


def build(chapters: list[dict]) -> dict:
    nodes, edges, layers, tour = [], [], [], []
    ids_by_name: dict[str, list[str]] = {}
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
            ids_by_name.setdefault(normalise_name(concept["name"]), []).append(node_id)
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
        edges.extend(
            {
                "source": other,
                "target": same[0],
                "type": "similar_to",
                "description": "same idea in another chapter",
            }
            for other in same[1:]
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
