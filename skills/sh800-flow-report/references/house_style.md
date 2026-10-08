# Lab document house style — shared spec

Every lab skill builds its `.docx` by assembling a JSON **doc spec** and running
`build_docx.py spec.json output.docx`. Because all four skills share the same
renderer, every document the PI receives looks identical: same cardinal-red
headings, same metadata block at the top, same table and figure styling. Do not
hand-format Word files — always go through the builder so uniformity is
guaranteed.

## Top-level spec

```json
{
  "doc_type": "Results Report",        // kicker label at the very top (uppercased)
  "title": "Short descriptive title",  // large heading under the kicker
  "footer": "Gawad Lab · Stanford",    // optional centered footer line
  "meta": {                              // metadata block; render every field
    "Lab member": "...",
    "Date": "...",
    "Project / Aim": "..."
  },
  "sections": [
    { "heading": "1. Section title", "blocks": [ ... ] }
  ]
}
```

`meta` is an ordered map — the keys you include and their order are up to the
skill, but keep them consistent within a doc type so the PI always sees the same
header. Always include at minimum: **Lab member**, **Date**, **Project / Aim**.

## Block types (inside a section's `blocks` array)

- `{"type":"paragraph","text":"..."}` — body prose.
- `{"type":"bullets","items":["...","..."]}` — bulleted list.
- `{"type":"numbered","items":["...","..."]}` — numbered list (use for ordered
  procedure steps).
- `{"type":"keyvalue","rows":[["Platform","10x Chromium"],["n cells","8,412"]]}`
  — a two-column labelled facts table (good for methods/parameters).
- `{"type":"table","columns":["Col A","Col B"],"rows":[["...","..."]]}` — a full
  table with a shaded header row.
- `{"type":"figure","path":"fig1.png","caption":"Figure 1. ..."}` — embeds an
  image if the file exists, otherwise writes a labelled placeholder so the PI
  can see what is missing. Ask the member for real figure files whenever
  possible.
- `{"type":"callout","label":"DECISION NEEDED","text":"..."}` — a shaded box
  with a left accent bar. Use for blockers, decisions the PI must make, or
  safety warnings.

## Rules

- Keep section numbering and titles fixed per doc type (defined in each skill).
  The PI relies on section N always meaning the same thing.
- Prefer `keyvalue`/`table` for anything parameter-like (QC thresholds, sample
  counts, reagent lists) — structured data reads faster than prose.
- Never invent numbers, sample counts, or results. Only include what the member
  provided or what is in the documents they attached. If a required field is
  unknown, write "not provided" rather than guessing.
