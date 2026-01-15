# wire - Declarative network configuration tool for Linux
# Makefile for building and installation
#
# Usage:
#   make                    # Build for native platform
#   make install            # Install all files (run as root)
#   make deploy             # Deploy binary to test VM
#
# Cross-compilation (use zig directly):
#   zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe

PREFIX ?= /usr/local
SBINDIR ?= $(PREFIX)/sbin
MANDIR ?= $(PREFIX)/share/man
SYSCONFDIR ?= /etc
SYSTEMDDIR ?= /lib/systemd/system
BASHCOMPDIR ?= /etc/bash_completion.d
ZSHCOMPDIR ?= $(PREFIX)/share/zsh/site-functions
FISHCOMPDIR ?= $(PREFIX)/share/fish/vendor_completions.d

ZIG ?= zig
ZIGFLAGS ?= -Doptimize=ReleaseSafe

.PHONY: all build clean install uninstall install-bin install-man install-completions install-systemd install-config

all: build

# Note: For cross-compilation, use zig build directly:
#   zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
build:
	$(ZIG) build $(ZIGFLAGS)

clean:
	rm -rf zig-out .zig-cache

# Install everything
install: install-bin install-man install-completions install-systemd install-config
	@echo "Installation complete."
	@echo "Edit $(SYSCONFDIR)/wire/network.conf and run: systemctl enable --now wire"

# Install binary only
install-bin:
	install -D -m 0755 zig-out/bin/wire $(DESTDIR)$(SBINDIR)/wire

# Install man pages
install-man:
	install -D -m 0644 man/man8/wire.8 $(DESTDIR)$(MANDIR)/man8/wire.8
	install -D -m 0644 man/man5/wire.conf.5 $(DESTDIR)$(MANDIR)/man5/wire.conf.5

# Install shell completions
install-completions:
	install -D -m 0644 completions/wire.bash $(DESTDIR)$(BASHCOMPDIR)/wire
	install -D -m 0644 completions/wire.zsh $(DESTDIR)$(ZSHCOMPDIR)/_wire
	install -D -m 0644 completions/wire.fish $(DESTDIR)$(FISHCOMPDIR)/wire.fish

# Install systemd service
install-systemd:
	install -D -m 0644 systemd/wire.service $(DESTDIR)$(SYSTEMDDIR)/wire.service

# Install configuration files
install-config:
	install -d -m 0755 $(DESTDIR)$(SYSCONFDIR)/wire
	install -d -m 0755 $(DESTDIR)$(SYSCONFDIR)/wire/conf.d
	@if [ ! -f $(DESTDIR)$(SYSCONFDIR)/wire/network.conf ]; then \
		install -m 0644 packaging/network.conf.default $(DESTDIR)$(SYSCONFDIR)/wire/network.conf; \
	else \
		echo "$(SYSCONFDIR)/wire/network.conf already exists, not overwriting"; \
	fi
	install -m 0644 examples/network.conf $(DESTDIR)$(SYSCONFDIR)/wire/network.conf.example

# Uninstall everything
uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/wire
	rm -f $(DESTDIR)$(MANDIR)/man8/wire.8
	rm -f $(DESTDIR)$(MANDIR)/man5/wire.conf.5
	rm -f $(DESTDIR)$(BASHCOMPDIR)/wire
	rm -f $(DESTDIR)$(ZSHCOMPDIR)/_wire
	rm -f $(DESTDIR)$(FISHCOMPDIR)/wire.fish
	rm -f $(DESTDIR)$(SYSTEMDDIR)/wire.service
	@echo "Configuration files in $(SYSCONFDIR)/wire/ were not removed."

# Development helpers
.PHONY: test fmt deploy

test:
	$(ZIG) build test

fmt:
	$(ZIG) fmt src/

# Deploy to test VM (adjust as needed)
TESTVM ?= root@10.0.0.20
deploy: build
	scp zig-out/bin/wire $(TESTVM):/usr/local/sbin/
	@echo "Deployed to $(TESTVM)"
