.PHONY: all
all: test

TEST_PATH := $(if $(TEST_PATH),$(TEST_PATH),lua/diffview/tests/)
export TEST_PATH

# Usage:
# 	Run all tests:
# 	$ make test
#
# 	Run tests for a specific path:
# 	$ TEST_PATH=tests/some/path make test
.PHONY: test
test:
	nvim --headless -i NONE -n -u scripts/minimal_init.lua -c \
		"PlenaryBustedDirectory $(TEST_PATH) { minimal_init = './scripts/minimal_init.lua' }"

.PHONY: clean
clean:
	rm -rf .tests
