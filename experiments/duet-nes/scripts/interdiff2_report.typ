// Report for nes_interdiff2.lua. Compile per variant:
//   typst compile --root <repo> --input data=/experiments/duet-nes/logs/interdiff2_TS/report_R.json \
//     experiments/duet-nes/scripts/interdiff2_report.typ out.pdf

#set page(paper: "a4", margin: 1.3cm, numbering: "1 / 1")
#set text(size: 9pt)
#set par(justify: false)
#show raw: set text(size: 6.6pt)
#show raw.where(block: true): it => block(fill: luma(245), inset: 4pt, radius: 2pt, width: 100%, it)

#let report = json(sys.inputs.at("data"))

#let classcolor(c) = {
  if c == "T2-hit" { rgb("#2b8a3e") } else if c == "T1" {
    rgb("#c92a2a")
  } else if c == "noapply" or c == "error" { rgb("#e8590c") } else if (
    c == "read" or c == "no_edit"
  ) { rgb("#868e96") } else { rgb("#f08c00") }
}
#let badge(c) = box(fill: classcolor(c), inset: (x: 4pt, y: 1pt), radius: 2pt)[
  #text(fill: white, weight: "bold", size: 7.5pt)[#c]
]
#let dispbadge(d) = box(fill: if d == "accepted" { rgb("#2b8a3e") } else { luma(150) }, inset: (x: 4pt, y: 1pt), radius: 2pt)[
  #text(fill: white, weight: "bold", size: 7.5pt)[#d]
]

#align(center)[
  #text(15pt, weight: "bold")[Inter-diff v2 · variant #report.variant]
  #linebreak()
  #text(10pt)[#report.label — tableau pivot, medium effort, accept-on-hit. \
  Detail = repeat 1; grid = all repeats. Disposition: #dispbadge("accepted") when the
  model nailed the exact next cell, else ignored.]
]
#v(4pt)

= Outcome grid (all repeats)
#let nrep = report.grid.at(0).classes.len()
#table(
  columns: (auto, auto) + (auto,) * nrep,
  inset: 3pt, align: horizon + left, stroke: 0.4pt + luma(210),
  table.header([*round*], [*user edit*], ..range(nrep).map(i => [*rep #(i + 1)*])),
  ..report.grid.map(g => ([#g.round], raw(g.edit), ..g.classes.map(c => badge(c)))).flatten(),
)

= Final-round transcript — what the model receives + produces (interleaved)
#text(8pt, fill: luma(90))[The full multi-turn log at the last round: system → session-start file →
(user: outcome + the actual edit + "predict next") → (assistant: #if report.variant == "R" [its own reasoning] else if report.variant == "N" [a self-note] else [—] + the patch) → … Reasoning is truncated for the page; the model received it in full.]
#raw(report.rounds.last().transcript, block: true, lang: none)

= Per-round summary (repeat 1)
#for s in report.rounds [
  #v(4pt)
  #text(11pt, weight: "bold")[Round #s.round] #h(5pt) #raw(s.target) #h(5pt) #badge(s.class) #h(3pt) #dispbadge(s.disposition)

  #if "note" in s and s.note != none [
    #text(9pt, weight: "bold", fill: rgb("#9c36b5"))[[💡 self-note carried forward]]
    #raw(s.note, block: true, lang: none)
  ]
  #text(9pt, weight: "bold", fill: rgb("#e8590c"))[[🤔 reasoning (excerpt)]]
  #raw(s.reasoning_excerpt, block: true, lang: none)
  #text(9pt, weight: "bold", fill: rgb("#2b8a3e"))[[📝 answer]]
  #raw(s.patch, block: true, lang: none)
  #line(length: 100%, stroke: 0.3pt + luma(210))
]
