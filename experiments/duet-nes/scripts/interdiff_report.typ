// Report template for nes_interdiff.lua. Compile per variant:
//   typst compile --root <repo> --input data=/experiments/duet-nes/logs/interdiff_TS/report_B.json \
//     experiments/duet-nes/scripts/interdiff_report.typ out.pdf
// `data` is a project-root-relative path (leading /) to a report_<V>.json.

#set page(paper: "a4", margin: 1.3cm, numbering: "1 / 1")
#set text(size: 9pt)
#set par(justify: false)
#show raw: set text(size: 6.6pt)
#show raw.where(block: true): it => block(
  fill: luma(245), inset: 4pt, radius: 2pt, width: 100%, it,
)

#let report = json(sys.inputs.at("data"))

#let classcolor(c) = {
  if c == "T2-hit" { rgb("#2b8a3e") } else if c == "T1" {
    rgb("#c92a2a")
  } else if c == "noapply" or c == "error" { rgb("#e8590c") } else if (
    c == "read" or c == "no_edit"
  ) { rgb("#868e96") } else { rgb("#f08c00") } // T2-other / other
}
#let badge(c) = box(fill: classcolor(c), inset: (x: 4pt, y: 1pt), radius: 2pt)[
  #text(fill: white, weight: "bold", size: 7.5pt)[#c]
]

#align(center)[
  #text(15pt, weight: "bold")[Inter-diff memory · variant #report.variant]
  #linebreak()
  #text(10pt)[#report.label — tableau pivot, medium effort. \
  Per-step detail is repeat 1; the grid covers all repeats. T2-hit = exact next
  cell · T2-other = right table, wrong value/revert · T1 = wrong table.]
]
#v(4pt)

= Outcome grid (all repeats)
#let nrep = report.grid.at(0).classes.len()
#table(
  columns: (auto, auto) + (auto,) * nrep,
  inset: 3pt,
  align: horizon + left,
  stroke: 0.4pt + luma(210),
  table.header([*step*], [*user edit*], ..range(nrep).map(i => [*rep #(i + 1)*])),
  ..report.grid.map(g => (
    [#g.step],
    raw(g.edit),
    ..g.classes.map(c => badge(c)),
  )).flatten(),
)

#if "base_example" in report and report.base_example != none [
  = What the model receives — shared base (example: step 3)
  #text(8pt, fill: luma(90))[cursor note → recent edits (apply_patch diffs) → the
  whole file. Identical across variants; only the trailer below differs.]
  #raw(report.base_example, block: true, lang: none)
]

= Per-step detail (repeat 1)
#for s in report.steps [
  #v(5pt)
  #text(12pt, weight: "bold")[Step #s.step] #h(6pt) #raw(s.edit) #h(6pt) #badge(s.class)

  #if "summary" in s and s.summary != none [
    #text(9pt, weight: "bold", fill: rgb("#9c36b5"))[[💡 carried intent summary]]
    #raw(s.summary, block: true, lang: none)
  ]

  #text(9pt, weight: "bold", fill: rgb("#1971c2"))[[🧩 end-of-prompt trailer the model receives]]
  #raw(s.trailer, block: true, lang: none)

  #text(9pt, weight: "bold", fill: rgb("#e8590c"))[[🤔 model reasoning (excerpt)]]
  #raw(s.reasoning_excerpt, block: true, lang: none)

  #text(9pt, weight: "bold", fill: rgb("#2b8a3e"))[[📝 model answer]]
  #raw(s.patch, block: true, lang: none)

  #v(3pt)
  #line(length: 100%, stroke: 0.3pt + luma(210))
]
