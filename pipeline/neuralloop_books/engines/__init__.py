"""Engines make a book's study items. `pipeline.run` only talks to this interface:

    name: str                                   shown in messages ("Claude", "NotebookLM")
    async with engine: ...                      open and close connections
    async prepare(state)                        check setup; NotebookLM also adds chapters as sources
    async make(task, chapter) -> dict           the fields to store on the chapter

Two engines: `local` (any text model + a speech engine) and `notebooklm` (Google NotebookLM).
"""
