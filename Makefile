PREFIX ?= $(HOME)/.local
BIN := machine-report

$(BIN): machine_report.swift
	swiftc -O $< -o $@

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: install clean
