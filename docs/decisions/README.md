# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for FluxCore.

## Format

Each ADR is a numbered Markdown file: `NNNN-short-title.md`.

An ADR contains:
- **Context** — why was this decision necessary?
- **Decision** — what was decided?
- **Benefits** — what does this choice enable?
- **Costs** — what does this choice constrain or complicate?
- **Revisit conditions** — when should this decision be revisited?

## Index

| Number | Title                          | File                                        |
|--------|--------------------------------|---------------------------------------------|
| 0001   | BRAM-first memory strategy     | [0001-bram-first.md](0001-bram-first.md)    |
| 0002   | Board model unconfirmed        | [0002-board-model-unconfirmed.md](0002-board-model-unconfirmed.md) |

## Writing New ADRs

Write a new ADR whenever you make a non-obvious architectural or
implementation choice. Decision context decays quickly — write the record
at the time of the decision, not retrospectively.

Assign the next sequential number. Commit the ADR in the same commit as
the code change it documents.
