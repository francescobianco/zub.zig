PREFIX ?= $(HOME)/.local
ZIG_VERSION ?= 0.15.1
ZVM_ZIG := $(HOME)/.zvm/$(ZIG_VERSION)/zig
ZIG ?= $(if $(wildcard $(ZVM_ZIG)),$(ZVM_ZIG),zig)
OPTIMIZE ?= ReleaseSafe

.PHONY: build install clean

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

install:
	mkdir -p $(PREFIX)/bin
	$(ZIG) build -Doptimize=$(OPTIMIZE) --prefix $(PREFIX)

clean:
	rm -rf zig-out .zig-cache zig-cache
