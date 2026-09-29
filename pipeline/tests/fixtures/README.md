# Fixtures

`book.json` is a real payload from `nl_book.py --dry-run --chapters 1-2 --media 1` (chapter text trimmed), shared by
`tests/test_pipeline.py` (it must keep every field the pipeline writes) and `apple/Tests` (the Swift app must decode it).
Regenerate it when the book-data contract changes, in the same commit as the contract change.
