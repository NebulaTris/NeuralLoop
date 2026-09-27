"""Parsing chapter selections such as "1-3,5", "all", or "none"."""

import re

_SPEC = re.compile(r"^\d+(-\d+)?(,\d+(-\d+)?)*$")


def parse_selection(spec: str, chapter_count: int) -> set[int]:
    """Return the chapter numbers selected by ``spec``, limited to 1..chapter_count."""
    spec = spec.strip().lower().replace(" ", "")
    if spec == "all":
        return set(range(1, chapter_count + 1))
    if spec == "none":
        return set()
    if not _SPEC.match(spec):
        raise ValueError(f'Invalid chapter selection "{spec}". Use forms like 1-3, 1,4,7, all, or none.')
    chosen: set[int] = set()
    for part in spec.split(","):
        start, _, end = part.partition("-")
        low, high = int(start), int(end or start)
        if low > high:
            raise ValueError(f'Invalid range "{part}": the first number must not be larger than the second.')
        chosen.update(range(low, high + 1))
    return {n for n in chosen if 1 <= n <= chapter_count}
