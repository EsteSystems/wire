Name:           wire
Version:        1.0.0
Release:        1%{?dist}
Summary:        Declarative network configuration tool for Linux

License:        BSD
URL:            https://github.com/EsteSystems/wire
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  zig >= 0.11.0

Requires:       iproute

%description
Wire is a low-level, declarative, continuously-supervised network
configuration tool for Linux. It combines the direct kernel access of
iproute2 with the desired-state model of infrastructure-as-code tools,
wrapped in a natural language CLI.

Features:
- Direct netlink operation (no command wrapping)
- Unified syntax (CLI = config file format)
- Continuous supervision with drift detection
- Built-in network analysis and diagnostics
- Bond, bridge, VLAN, tunnel management
- Traffic control and hardware tuning

%prep
%setup -q

%build
zig build -Doptimize=ReleaseSafe

%install
rm -rf %{buildroot}

# Binary
install -D -m 0755 zig-out/bin/wire %{buildroot}%{_sbindir}/wire

# Man pages
install -D -m 0644 man/man8/wire.8 %{buildroot}%{_mandir}/man8/wire.8
install -D -m 0644 man/man5/wire.conf.5 %{buildroot}%{_mandir}/man5/wire.conf.5

# Systemd service
install -D -m 0644 systemd/wire.service %{buildroot}%{_unitdir}/wire.service

# Configuration directory and example
install -d -m 0755 %{buildroot}%{_sysconfdir}/wire
install -d -m 0755 %{buildroot}%{_sysconfdir}/wire/conf.d
install -D -m 0644 examples/simple.conf %{buildroot}%{_sysconfdir}/wire/network.conf.example

# Shell completions
install -D -m 0644 completions/wire.bash %{buildroot}%{_datadir}/bash-completion/completions/wire
install -D -m 0644 completions/wire.zsh %{buildroot}%{_datadir}/zsh/site-functions/_wire
install -D -m 0644 completions/wire.fish %{buildroot}%{_datadir}/fish/vendor_completions.d/wire.fish

%post
%systemd_post wire.service

%preun
%systemd_preun wire.service

%postun
%systemd_postun_with_restart wire.service

%files
%license LICENSE
%doc README.md
%doc examples/
%{_sbindir}/wire
%{_mandir}/man8/wire.8*
%{_mandir}/man5/wire.conf.5*
%{_unitdir}/wire.service
%dir %{_sysconfdir}/wire
%dir %{_sysconfdir}/wire/conf.d
%config(noreplace) %{_sysconfdir}/wire/network.conf.example
%{_datadir}/bash-completion/completions/wire
%{_datadir}/zsh/site-functions/_wire
%{_datadir}/fish/vendor_completions.d/wire.fish

%changelog
* Wed Jan 15 2026 Este Systems <support@este.systems> - 1.0.0-1
- Initial 1.0.0 release
- Full interface, route, bond, bridge, VLAN management
- Daemon mode with drift detection and correction
- Network namespaces and policy routing
- Traffic control (qdiscs) and hardware tuning
- Built-in diagnostics: topology, trace, probe, capture
- Validation and continuous monitoring
