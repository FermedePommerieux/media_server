PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
SCANDIR := $(BINDIR)/scan
SYSTEMD_DIR := /etc/systemd/system
CONFIG := /etc/dvdarchiver.conf
REMOVE_CONF ?= 0
PY_SOURCES := $(wildcard bin/scan/*.py)

.PHONY: install uninstall fmt lint

install:
	./install.sh

uninstall:
	rm -f $(BINDIR)/scan_enqueue.sh $(BINDIR)/scan_consumer.sh
	rm -f $(addprefix $(SCANDIR)/,$(notdir $(PY_SOURCES)))
	rmdir --ignore-fail-on-non-empty $(SCANDIR) || true
	rm -f $(SYSTEMD_DIR)/dvdarchiver-scan-consumer.service $(SYSTEMD_DIR)/dvdarchiver-scan-consumer.path
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl disable --now dvdarchiver-scan-consumer.path >/dev/null 2>&1 || true; \
		systemctl daemon-reload; \
	fi
ifeq ($(REMOVE_CONF),1)
	@echo "Suppression de $(CONFIG)"
	rm -f $(CONFIG)
endif

fmt:
	@if command -v black >/dev/null 2>&1; then \
		black $(PY_SOURCES); \
	else \
		echo "black indisponible"; \
	fi

lint:
	@if command -v ruff >/dev/null 2>&1; then \
		ruff check $(PY_SOURCES); \
	else \
		echo "ruff indisponible"; \
	fi
