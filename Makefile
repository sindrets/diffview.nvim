.PHONY: all
all: dev test

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
	nvim --headless -i NONE -n -u scripts/test_init.lua -c \
		"PlenaryBustedDirectory $(TEST_PATH) { minimal_init = './scripts/test_init.lua' }"

.PHONY: dev
dev: .dev/lua/nvim

.dev/lua/nvim:
	mkdir -p "$@"
	git clone --filter=blob:none https://github.com/folke/neodev.nvim.git "$@/repo"
	cd "$@/repo" && git -c advice.detachedHead=false checkout ce9a2e8eaba5649b553529c5498acb43a6c317cd
	cp	"$@/repo/types/nightly/uv.lua" \
		"$@/repo/types/nightly/cmd.lua" \
		"$@/repo/types/nightly/alias.lua" \
		"$@/"
	rm -rf "$@/repo"

.PHONY: clean
clean:
	rm -rf .tests .dev
