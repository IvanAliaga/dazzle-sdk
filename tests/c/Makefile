# tests/c/Makefile — host-side unit tests for dazzle batch APIs.
#
# These tests exercise the snapshot-scan and flat-argv layout logic used by
# dazzle_snapshot_mhmget() and dazzle_pipeline_args() in
# core/transport/dazzle_transport.c.  They are self-contained and do not
# require the Valkey source tree, so they run on macOS/Linux with plain cc.
#
# Usage:
#   make          # build + run
#   make check    # alias for default
#   make clean

CC       ?= cc
CFLAGS   ?= -std=c11 -O0 -g -Wall -Wextra -Wpedantic -Wno-unused-parameter
LDFLAGS  ?=

TEST_BIN := test_batch
TEST_SRC := test_batch.c

.PHONY: all check clean
all: check

$(TEST_BIN): $(TEST_SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

check: $(TEST_BIN)
	./$(TEST_BIN)

clean:
	rm -f $(TEST_BIN)
