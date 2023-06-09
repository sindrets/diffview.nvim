.PHONY: all
all: test

.PHONY: test
test:
	nvim --headless -i NONE -n -u scripts/minimal_init.lua -c \
		"PlenaryBustedDirectory tests/ { minimal_init = './scripts/minimal_init.lua' }"

.PHONY: clean
clean:
	rm -rf .tests
