.PHONY: test test-unit test-integration test-e2e test-perf

NVIM ?= nvim
INIT := tests/minimal_init.lua

# Run the whole suite headless via plenary's busted harness.
test:
	$(NVIM) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedDirectory tests/ {minimal_init='$(INIT)', sequential=true}"

test-unit:
	$(NVIM) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedDirectory tests/unit/ {minimal_init='$(INIT)', sequential=true}"

test-integration:
	$(NVIM) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedDirectory tests/integration/ {minimal_init='$(INIT)', sequential=true}"

test-e2e:
	$(NVIM) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedDirectory tests/e2e/ {minimal_init='$(INIT)', sequential=true}"

test-perf:
	$(NVIM) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedDirectory tests/perf/ {minimal_init='$(INIT)', sequential=true}"
