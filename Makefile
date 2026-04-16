PREFIX ?= $(HOME)/.local
ZIG ?= zig
OPTIMIZE ?= ReleaseSafe

.PHONY: build install clean

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

install:
	mkdir -p $(PREFIX)/bin
	$(ZIG) build -Doptimize=$(OPTIMIZE) --prefix $(PREFIX)

clean:
	rm -rf zig-out .zig-cache zig-cache
