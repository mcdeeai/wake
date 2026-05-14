PREFIX ?= /usr/local
BIN    := $(PREFIX)/bin/wake
BUILT  := .build/release/wake

.PHONY: build install uninstall clamshell-setup clamshell-uninstall clean

build:
	swift build -c release

install: build
	sudo install -m 0755 $(BUILT) $(BIN)
	@echo "✓ installed: $(BIN)"

uninstall:
	sudo rm -f $(BIN)
	@echo "✓ removed: $(BIN)"

clamshell-setup: install
	sudo $(BIN) clamshell setup

clamshell-uninstall:
	sudo $(BIN) clamshell uninstall

clean:
	rm -rf .build
