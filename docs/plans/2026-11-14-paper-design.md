# Paper design (decided 2026-11-14)

This document records what the paper will contain and why. It was agreed with the user in one session on 2026-11-14, after two research passes: one over this project's own goal documents, one over related papers and venue norms. The step-by-step checklist that carries it out is [2026-11-14-paper-plan.md](2026-11-14-paper-plan.md).

## 1. Target and format

- **First target: the course report** (IIIT Bangalore project elective), due **2026-11-30**. It is written at full length, about 9000 words plus appendices.
- **Second target: a peer-reviewed venue**, after the course. The course version is structured so it can be cut to about 7500 words. Candidates found on 2026-11-14: IEEE ISPASS 2027 (abstract 2026-12-11, paper 2026-12-18; official call), ICPE 2027 (empirical paper type; the deadline came from a third-party tracker only and must be checked), the eBPF workshop, and CHEOPS for the storage results. The brief also lists CLOSER, a Scopus-indexed IEEE/Springer conference, IEEE Access and ACM Queue.
- **Format: LaTeX in `laptop/paper/`**, next to the data, so tables and figures are included straight from `analysis/`. This repo is public, so the draft is public as soon as it is pushed. A double-anonymous venue will need an anonymised copy.

## 2. Central question and storyline

The brief asks: **at what point does eBPF's low-overhead claim stop holding, compared with perf and a sidecar collector?** The paper follows the brief's own questions (the "brief-driven" storyline, chosen over a bottleneck-first or a methodology-first story).

| RQ | Question | Evidence |
|---|---|---|
| RQ1 | How much CPU does each mechanism add, in the workload and in its own process, as the rate grows? | `analysis/results/L_summary.md` Table 1; figures 1 and 2 |
| RQ2 | How do p50, p99 and p999 latency change? | Same |
| RQ3 | How much throughput does each mechanism cost at capacity, and when does it start losing events? | Table 2; figure 3 |
| RQ4 | How much does narrow scope save against wide scope? | Table 1; figures 1 and 2 |
| RQ5 | At what rate does each mechanism's cost pass a threshold, or pass another mechanism's? When does eBPF's claim hold? | New: cost per event and crossover table (section 4) |

## 3. Contributions as claimed

1. The first comparison of perf, eBPF (BCC) and an OpenTelemetry Collector under one harness: 3 workloads, 2 scopes, 4 rates, two independent blocks per cell, exact tests with Benjamini-Hochberg correction.
2. Tracing cost turns into throughput loss only when it lands on the bottleneck: wide tracing cuts redis's capacity by at least 40–60 % and nginx's by at least 12 %, and costs fio none.
3. When eBPF's claim holds: in narrow scope, yes; in wide scope, it costs less CPU than perf but not reliably less latency (on nginx its tail is worse).
4. Two measurement lessons: co-locating the load generator with the tracer biases the tail in a direction that depends on the tracer (Platform S data, nginx only, marked as such); and a single block of 6 traced runs against 2 baselines is null by construction under a 96-test correction, so two blocks are needed.

**Stated as limitations, not new runs (decided):** eBPF means BCC only (no bpftrace); the collector is the scraper mode only (no OTLP arm); one laptop, SMT off; eBPF's in-kernel time is not broken out, because `kernel.bpf_stats_enabled` would charge the traced runs only and break the A-B-A comparison (laptop PLAN decision 3.9). A one-night `bpf_stats` breakdown run may be considered for the venue version; it is not planned.

## 4. New analysis before writing (no new runs)

1. **Cost per event and crossover table** (`analysis/crossover.py`). Events per second come from each run's `mech_events` over its window. Added CPU per cell = the workload's extra cores + the tracer's own cores. A straight-line fit of added CPU against events per second, per workload, mechanism and scope, gives a fixed cost (cores) and a cost per event (ns of CPU per event). Rules fixed in the script before any number is computed: the threshold is **5 % extra workload CPU** (the drift limit); crossovers are reported **only within the tested rates**, never extrapolated, otherwise "no crossover within the tested range". Fallback if this runs late: report fixed cost and cost per event only, and move the crossover table to the venue version.
2. **Absolute values beside ratios**: untraced CPU (cores) and p99 (ms) per cell.
3. **Sample counts behind each percentile**: requests or I/Os per window.
4. **Setup table** generated from the provenance files: kernel, tool versions, CPU layout, buffer sizes.
5. **Literature**: about 12–15 papers for the course version (the 8 found on 2026-11-14, the 3 anchor papers, and the methodology papers), in `paper/references.bib` with DOIs. Cite the original papers, never the markdown conversions.

## 5. Section structure

| # | Section | Content |
|---|---|---|
| — | Abstract | Problem, method, 3–4 headline numbers |
| 1 | Introduction | Motivation, central question, RQ1–RQ5, contributions |
| 2 | Background | How perf, eBPF/BCC and the collector collect data and where each pays CPU; what scope means per mechanism |
| 3 | Related work | Five clusters, the closest papers, and a gap table |
| 4 | Methodology | Laptop and CPU layout, host controls, workloads and rate ladders, probes and commands per mechanism, run protocol (A-B-A, warm-ups, drift check, two blocks, randomised order), metric definitions, statistics, capacity test, provenance |
| 5 | Results | One subsection per RQ |
| 6 | Discussion and guidance | Bottleneck principle; when eBPF's claim holds (a short decision guide); scope advice; the collector; measurement lessons |
| 7 | Threats to validity | Internal, external and construct validity; every caveat flagged in the READMEs |
| 8 | Conclusion | Answers to RQ1–RQ5 |
| A | Reproducibility appendix | Versions, configuration, hardware, how to rerun; artifact location |
| B | Per-cell tables | Every estimate with its 95 % confidence interval |

## 6. Timeline

Dates are latest finish dates; any stage may finish early and the next starts at once. The order matters more than the dates.

| Dates | Work |
|---|---|
| Nov 14–17 | Section 4 analysis; LaTeX skeleton; literature and `references.bib` |
| Nov 18–22 | Methodology, Background, Results |
| Nov 23–26 | Discussion, Threats to validity, Related work, Introduction, Abstract |
| Nov 27–29 | Review: numbers check, consistency, LaTeX warnings, final read |
| Nov 30 | Submit the course version (the public repo at a fixed tag is the artifact) |
| December | Venue version: Zenodo DOI, anonymised copy, optional ISPASS |

Risk: the laptop PLAN assumed analysis ends on Nov 30 and writing starts after; both now run in parallel, so Nov 14–17 is the tight part.

## 7. Quality gates (publication standard)

- Every number in the text comes from a generated file; tables are included from `analysis/` output; a check script compares numbers typed into the text with those files.
- "Effect" means a tested result only; a null result is never "no overhead"; every caveat stays next to its number.
- One term per concept across the paper.
- Before each tag (`draft-v1`, `course-v1`): every analysis `--check` passes, LaTeX builds with no warnings, no unresolved references.
