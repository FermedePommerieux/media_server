PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
LIBDIR := $(PREFIX)/lib/dvdarchiver
SYSDDIR := /etc/systemd/system
UDEVDIR := /etc/udev/rules.d
CONFIG := /etc/dvdarchiver.conf

BIN_SCRIPTS := bin/do_rip.sh bin/queue_enqueue.sh bin/queue_consumer.sh
LIB_SCRIPTS := bin/lib/common.sh bin/lib/hash.sh bin/lib/techdump.sh
SYSTEMD_UNITS := systemd/dvdarchiver-queue-consumer.service systemd/dvdarchiver-queue-consumer.path systemd/dvdarchiver-queue-consumer.timer
UDEV_RULE := udev/99-dvdarchiver.rules

.PHONY: install uninstall lint test-shellcheck

install:
./install.sh --with-systemd --with-udev --prefix=$(PREFIX)

uninstall:
	rm -f $(addprefix $(BINDIR)/,$(notdir $(BIN_SCRIPTS)))
	rm -rf $(LIBDIR)
	rm -f $(addprefix $(SYSDDIR)/,$(notdir $(SYSTEMD_UNITS)))
	rm -f $(UDEVDIR)/$(notdir $(UDEV_RULE))

lint: test-shellcheck

test-shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(BIN_SCRIPTS) $(LIB_SCRIPTS); \
	else \
		echo "shellcheck non disponible"; \
	fi
