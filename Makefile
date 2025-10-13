PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
LIBDIR := $(PREFIX)/lib/dvdarchiver
SYSDDIR := /etc/systemd/system
UDEVDIR := /etc/udev/rules.d
CONFIG := /etc/dvdarchiver.conf

UNINSTALL_ARGS := --prefix=$(PREFIX)
ifeq ($(WITH_SYSTEMD),0)
UNINSTALL_ARGS += --no-systemd
endif
ifeq ($(WITH_UDEV),0)
UNINSTALL_ARGS += --no-udev
endif
ifeq ($(KEEP_MODEL),1)
UNINSTALL_ARGS += --keep-model
endif

BIN_SCRIPTS := dvd-archiver/bin/do_backup.sh bin/queue_enqueue.sh bin/queue_consumer.sh bin/scan_enqueue.sh bin/scan_consumer.sh
LIB_SCRIPTS := bin/lib/common.sh bin/lib/hash.sh bin/lib/techdump.sh
ROOT_SCRIPTS := install.sh uninstall.sh
SYSTEMD_UNITS := systemd/dvdarchiver-queue-consumer.service systemd/dvdarchiver-queue-consumer.path systemd/dvdarchiver-queue-consumer.timer \
                  systemd/dvdarchiver-scan-consumer.service systemd/dvdarchiver-scan-consumer.path
UDEV_RULE := udev/99-dvdarchiver.rules
PY_SOURCES := $(wildcard bin/scan/*.py)

.PHONY: install uninstall lint fmt test test-shellcheck

install:
	./install.sh --with-systemd --with-udev --prefix=$(PREFIX)

uninstall:
	./uninstall.sh $(UNINSTALL_ARGS)

lint:
	@if command -v ruff >/dev/null 2>&1; then \
		ruff check $(PY_SOURCES); \
	else \
		echo "ruff non disponible"; \
	fi
	$(MAKE) test-shellcheck

fmt:
	@if command -v black >/dev/null 2>&1; then \
		black $(PY_SOURCES); \
	else \
		echo "black non disponible"; \
	fi

test:
	python3 -m compileall bin/scan

test-shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
                shellcheck $(BIN_SCRIPTS) $(LIB_SCRIPTS) $(ROOT_SCRIPTS); \
	else \
		echo "shellcheck non disponible"; \
	fi
