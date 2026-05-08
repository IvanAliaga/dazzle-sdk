# Makefile — reproduce the §5.9 / §5.9.5 paper artifacts from raw JSONs.
#
# Run from `research/paper/`. Targets:
#
#   make reproduce       — run all aggregators + recall + PDFs
#   make tables          — run aggregators only (cross-platform table +
#                          per-chip cell means + paired ratios + latency
#                          decomposition + recall@k)
#   make pdf             — regenerate paper.pdf and paper_es.pdf from md
#   make clean           — remove generated tex / log / aux
#
# Inputs the aggregators expect (paths relative to repo root):
#
#   research/results/cross_platform_e2e/g30_sd662_rag_e2e.json
#   research/results/cross_platform_e2e/ane_kirin659_rag_e2e.json
#   research/results/cross_platform_e2e/frl_l23_helio_g80_rag_e2e.json   (optional)
#   research/benchmarks/results/Moto_G35_5G/rag_2x2/rag_e2e_moto_g35_5G_1777395311213.json
#   /tmp/{kirin_passage_embeds.bin, kirin_query_embeds.bin,
#         kirin_queries.json, kirin_passages.json}                       (recall@k)
#
# Required tools on $PATH: python3 (numpy), pandoc, tectonic, sed.
#
# A reviewer who clones the repo can run `make -C research/paper reproduce`
# and the §5.9.5 tables + PDFs regenerate from the JSONs alone — no device,
# no Android SDK, no native build.

REPO    := $(shell git rev-parse --show-toplevel 2>/dev/null || echo ../..)
PAPER   := $(REPO)/research/paper
SCRIPTS := $(REPO)/research/scripts
BUILD   := $(PAPER)/arxiv-build
RESULTS := $(REPO)/research/results/cross_platform_e2e
PYTHON  ?= python3
TEX_PATH := /Library/TeX/texbin:$(PATH)

.PHONY: reproduce tables pdf clean help

reproduce: tables pdf
	@echo
	@echo "=== reproduce complete ==="
	@echo "tables: $(RESULTS)/rag_2x2_cross_platform.md"
	@echo "PDFs:   $(BUILD)/paper.pdf  +  $(BUILD)/paper_es.pdf"

tables:
	@echo "=== bootstrap aggregator (per-chip cell means + paired ratios + latency decomp) ==="
	$(PYTHON) $(SCRIPTS)/bootstrap_rag_cross_platform.py \
		--out $(RESULTS)/rag_2x2_cross_platform.md
	@echo
	@echo "=== BGE recall@k (chip-invariant retrieval upper bound) ==="
	@if [ -f /tmp/kirin_passage_embeds.bin ]; then \
		$(PYTHON) $(SCRIPTS)/bge_recall_at_k.py ; \
	else \
		echo "  /tmp/kirin_*.bin not found — skip recall@k. To regenerate," ; \
		echo "  pull the cache off-device (see investigation md §pass 16)." ; \
	fi

# tex regen: `regen_body_tex.sh` strips our manual section-number prefixes
# (e.g. "## 5.9.1 Setup") so pandoc emits LaTeX that arxiv.sty can
# auto-number; otherwise the PDF would show "5.9.1 5.9.1 Setup".
pdf:
	@echo "=== regen body.tex (EN + ES) from paper_v2_*.md ==="
	bash $(SCRIPTS)/regen_body_tex.sh
	@echo "=== compile paper.pdf + paper_es.pdf via tectonic ==="
	@cd $(BUILD) && PATH="$(TEX_PATH)" tectonic paper.tex
	@cd $(BUILD) && PATH="$(TEX_PATH)" tectonic paper_es.tex

clean:
	rm -f $(BUILD)/paper.aux $(BUILD)/paper.log $(BUILD)/paper.out \
	      $(BUILD)/paper.bbl $(BUILD)/paper.blg \
	      $(BUILD)/paper_es.aux $(BUILD)/paper_es.log $(BUILD)/paper_es.out \
	      $(BUILD)/paper_es.bbl $(BUILD)/paper_es.blg

help:
	@echo "make reproduce  — run aggregators + regen PDFs"
	@echo "make tables     — aggregators only (md output)"
	@echo "make pdf        — md → tex → pdf"
	@echo "make clean      — remove tex aux files"
