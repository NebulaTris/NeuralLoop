"""Prompts sent to NotebookLM's chat. Each asks for JSON only; see convert.py for parsing."""

STUDY = """Using ONLY the source titled "{title}", prepare study material for a software engineer.
Reply with ONLY a JSON object, no prose, no citations, in exactly this shape:
{{"guide":[{{"section":"a section heading from the source","level":"deep|normal|skim","why":"max 18 words: what to focus on"}}],
"recall":[{{"prompt":"an open question asking to explain or apply an idea in your own words","keyPoints":["short point a good answer covers"]}}]}}
Rules: one guide entry per major section, marking dense new ideas "deep" and familiar or example-heavy parts "skim";
exactly 3 recall prompts with 3-5 keyPoints each; prefer "explain" and "what would you do if" questions over definitions."""

GRAPH = """Using ONLY the source titled "{title}", build a concept graph for a software engineer studying it.
Reply with ONLY a JSON object, no prose, no citations, in exactly this shape:
{{"concepts":[{{"id":"kebab-case-id","name":"2-5 words","type":"concept|claim|topic","summary":"max 25 words","detail":"max 45 words","complexity":"simple|moderate|complex","layer":"layer id"}}],
"layers":[{{"id":"short-id","name":"2-3 words"}}],
"edges":[{{"source":"concept id","target":"concept id","type":"depends_on|builds_on|related|contradicts|exemplifies|categorized_under","description":"max 8 words"}}],
"tour":[{{"title":"max 6 words","description":"max 30 words","nodeIds":["concept ids"]}}]}}
Rules: 8-14 concepts; include up to 3 claims (positions the author argues); 2-4 layers grouping concepts by role;
edges point from the idea that needs or builds on another to that other idea; 3-5 tour steps, prerequisites first."""
