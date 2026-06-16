// Focused view of ONE round of an interdiff3 report (the full prompt the model
// receives — interleaved accept/ignore memory then the whole tableau — plus its
// response). Compile:
//   typst compile --root <repo> --input data=/…/report_F.json \
//     experiments/duet-nes/scripts/interdiff_round.typ out.pdf
// Optional: --input round=N (default = last round).

#set page(paper: "a4", margin: 1.3cm, numbering: "1 / 1")
#set text(size: 9pt)
#set par(justify: false)
#show raw: set text(size: 6.8pt)
#show raw.where(block: true): it => block(fill: luma(245), inset: 4pt, radius: 2pt, width: 100%, it)

#let report = json(sys.inputs.at("data"))
#let rounds = report.rounds
#let pick = sys.inputs.at("round", default: "last")
#let r = if pick == "last" { rounds.last() } else { rounds.find(x => str(x.round) == pick) }

#let classcolor(c) = {
  if c == "T2-hit" { rgb("#2b8a3e") } else if c == "T1" { rgb("#c92a2a") } else if (c == "noapply" or c == "error") { rgb("#e8590c") } else if (c == "read" or c == "no_edit") { rgb("#868e96") } else { rgb("#f08c00") }
}
#let badge(txt, col) = box(fill: col, inset: (x: 5pt, y: 1pt), radius: 2pt)[#text(fill: white, weight: "bold", size: 8pt)[#txt]]

#align(center)[
  #text(14pt, weight: "bold")[Inter-diff memory · variant #report.variant — mid-pivot round #r.round]
  #linebreak()
  #text(9.5pt)[#report.label. The full payload the model receives: its earlier guesses + the
  user's #badge("accepted", rgb("#2b8a3e")) / ignored verdicts, interleaved, then the whole
  current tableau — followed by what it produced.]
  #linebreak()
  #v(2pt)
  target this round: #raw(r.target) #h(8pt) outcome: #badge(r.class, classcolor(r.class)) #h(4pt) #badge(r.disposition, if r.disposition == "accepted" { rgb("#2b8a3e") } else { luma(140) })
]
#v(5pt)

= What the model receives (interleaved memory → full tableau) + its response
#text(8pt, fill: luma(90))[Roles: SYSTEM → (USER: the user's edit / the outcome of your last
suggestion) → (ASSISTANT: your prior patch) … → final USER carrying the whole current file.]
#raw(r.transcript, block: true, lang: none)

#v(6pt)
#line(length: 100%, stroke: 0.4pt + luma(200))
#text(10pt, weight: "bold", fill: rgb("#e8590c"))[[🤔 model reasoning this round (excerpt)]]
#raw(r.reasoning_excerpt, block: true, lang: none)
#text(10pt, weight: "bold", fill: rgb("#2b8a3e"))[[📝 model answer this round]]
#raw(r.patch, block: true, lang: none)
