# wire fish completion script
# Install: cp wire.fish ~/.config/fish/completions/

# Disable file completion by default
complete -c wire -f

# Helper function to check command position
function __fish_wire_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __fish_wire_using_command
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2 && test $cmd[2] = $argv[1]
end

function __fish_wire_using_subcommand
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 3 && test $cmd[2] = $argv[1] && test $cmd[3] = $argv[2]
end

# Get interface names
function __fish_wire_interfaces
    ip -o link show 2>/dev/null | string replace -r '^[0-9]+: ([^:@]+).*' '$1'
end

# Get network namespaces
function __fish_wire_namespaces
    ls /var/run/netns 2>/dev/null
end

# Get bridge interfaces
function __fish_wire_bridges
    ip -o link show type bridge 2>/dev/null | string replace -r '^[0-9]+: ([^:]+).*' '$1'
end

# Main commands
complete -c wire -n __fish_wire_needs_command -a interface -d "Interface management"
complete -c wire -n __fish_wire_needs_command -a route -d "Routing table"
complete -c wire -n __fish_wire_needs_command -a neighbor -d "ARP/NDP table"
complete -c wire -n __fish_wire_needs_command -a bond -d "Bond interface management"
complete -c wire -n __fish_wire_needs_command -a bridge -d "Bridge interface management"
complete -c wire -n __fish_wire_needs_command -a vlan -d "VLAN interface management"
complete -c wire -n __fish_wire_needs_command -a veth -d "Veth pair management"
complete -c wire -n __fish_wire_needs_command -a tunnel -d "VXLAN/GRE tunnel management"
complete -c wire -n __fish_wire_needs_command -a rule -d "IP policy routing rules"
complete -c wire -n __fish_wire_needs_command -a netns -d "Network namespace management"
complete -c wire -n __fish_wire_needs_command -a tc -d "Traffic control (qdiscs)"
complete -c wire -n __fish_wire_needs_command -a hw -d "Hardware tuning (ethtool)"
complete -c wire -n __fish_wire_needs_command -a topology -d "Show network topology"
complete -c wire -n __fish_wire_needs_command -a diagnose -d "Network diagnostics"
complete -c wire -n __fish_wire_needs_command -a trace -d "Trace path to destination"
complete -c wire -n __fish_wire_needs_command -a probe -d "Test TCP connectivity"
complete -c wire -n __fish_wire_needs_command -a watch -d "Continuous monitoring"
complete -c wire -n __fish_wire_needs_command -a analyze -d "Analyze network configuration"
complete -c wire -n __fish_wire_needs_command -a apply -d "Apply configuration file"
complete -c wire -n __fish_wire_needs_command -a validate -d "Validate configuration"
complete -c wire -n __fish_wire_needs_command -a diff -d "Compare config vs live state"
complete -c wire -n __fish_wire_needs_command -a state -d "Show current network state"
complete -c wire -n __fish_wire_needs_command -a events -d "Monitor network events"
complete -c wire -n __fish_wire_needs_command -a daemon -d "Supervision daemon control"
complete -c wire -n __fish_wire_needs_command -a history -d "Change history and snapshots"
complete -c wire -n __fish_wire_needs_command -s h -l help -d "Show help"
complete -c wire -n __fish_wire_needs_command -s v -l version -d "Show version"

# interface subcommands
complete -c wire -n "__fish_wire_using_command interface" -a "(__fish_wire_interfaces)" -d "Interface"
complete -c wire -n "__fish_wire_using_command interface && test (count (commandline -opc)) -eq 3" -a "show set address delete stats" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand interface set" -a "state mtu mac" -d "Property"
complete -c wire -n "__fish_wire_using_subcommand interface address" -a "del" -d "Action"

# route subcommands
complete -c wire -n "__fish_wire_using_command route" -a "show add del default help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand route add" -a "via dev default" -d "Option"

# neighbor subcommands
complete -c wire -n "__fish_wire_using_command neighbor" -a "show list lookup arp add del help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand neighbor add" -a "lladdr dev permanent" -d "Option"
complete -c wire -n "__fish_wire_using_subcommand neighbor del" -a "dev" -d "Option"

# bond subcommands
complete -c wire -n "__fish_wire_using_command bond" -a "create delete add remove show help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand bond create" -a "mode miimon lacp_rate xmit_hash_policy" -d "Option"

# bridge subcommands
complete -c wire -n "__fish_wire_using_command bridge" -a "(__fish_wire_bridges) create delete add remove fdb help" -d "Bridge/Action"
complete -c wire -n "__fish_wire_using_command bridge && test (count (commandline -opc)) -eq 3" -a "show add remove fdb delete" -d "Action"

# vlan subcommands
complete -c wire -n "__fish_wire_using_command vlan" -a "create delete show help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand vlan create" -a "id on" -d "Option"

# veth subcommands
complete -c wire -n "__fish_wire_using_command veth" -a "peer delete show netns help" -d "Action"

# tunnel subcommands
complete -c wire -n "__fish_wire_using_command tunnel" -a "vxlan gre gretap geneve ipip sit wireguard delete help" -d "Type/Action"
complete -c wire -n "__fish_wire_using_subcommand tunnel vxlan" -a "vni local group port learning nolearning" -d "Option"
complete -c wire -n "__fish_wire_using_subcommand tunnel gre" -a "local remote key ttl" -d "Option"
complete -c wire -n "__fish_wire_using_subcommand tunnel gretap" -a "local remote key ttl" -d "Option"
complete -c wire -n "__fish_wire_using_subcommand tunnel geneve" -a "id remote port ttl" -d "Option"
complete -c wire -n "__fish_wire_using_subcommand tunnel ipip" -a "local remote ttl" -d "Option"
complete -c wire -n "__fish_wire_using_subcommand tunnel sit" -a "local remote ttl" -d "Option"

# rule subcommands
complete -c wire -n "__fish_wire_using_command rule" -a "show list add del help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand rule add" -a "from to fwmark table prio iif oif blackhole unreachable prohibit" -d "Option"

# netns subcommands
complete -c wire -n "__fish_wire_using_command netns" -a "list show add create del delete exec set help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand netns exec && test (count (commandline -opc)) -eq 3" -a "(__fish_wire_namespaces)" -d "Namespace"
complete -c wire -n "__fish_wire_using_subcommand netns exec && test (count (commandline -opc)) -eq 4" -a "wire ip ss ping iptables nft bash sh" -d "Command"
complete -c wire -n "__fish_wire_using_subcommand netns del" -a "(__fish_wire_namespaces)" -d "Namespace"
complete -c wire -n "__fish_wire_using_subcommand netns delete" -a "(__fish_wire_namespaces)" -d "Namespace"
complete -c wire -n "__fish_wire_using_subcommand netns set && test (count (commandline -opc)) -eq 3" -a "(__fish_wire_interfaces)" -d "Interface"
complete -c wire -n "__fish_wire_using_subcommand netns set && test (count (commandline -opc)) -eq 4" -a "(__fish_wire_namespaces)" -d "Namespace"

# tc subcommands
complete -c wire -n "__fish_wire_using_command tc" -a "(__fish_wire_interfaces) help" -d "Interface"
complete -c wire -n "__fish_wire_using_command tc && test (count (commandline -opc)) -eq 3" -a "show add del class filter" -d "Action"
complete -c wire -n "__fish_wire_using_command tc && test (count (commandline -opc)) -eq 4 && test (commandline -opc)[4] = add" -a "pfifo fq_codel tbf htb" -d "Qdisc type"
complete -c wire -n "__fish_wire_using_command tc && test (count (commandline -opc)) -eq 4 && test (commandline -opc)[4] = class" -a "show add del" -d "Class action"
complete -c wire -n "__fish_wire_using_command tc && test (count (commandline -opc)) -ge 5 && test (commandline -opc)[4] = class && test (commandline -opc)[5] = add" -a "rate ceil prio" -d "Class option"
complete -c wire -n "__fish_wire_using_command tc && test (count (commandline -opc)) -eq 4 && test (commandline -opc)[4] = filter" -a "show add del" -d "Filter action"
complete -c wire -n "__fish_wire_using_command tc && test (count (commandline -opc)) -eq 5 && test (commandline -opc)[4] = filter && test (commandline -opc)[5] = add" -a "u32 fw" -d "Filter type"

# hw subcommands
complete -c wire -n "__fish_wire_using_command hw" -a "(__fish_wire_interfaces) help" -d "Interface"
complete -c wire -n "__fish_wire_using_command hw && test (count (commandline -opc)) -eq 3" -a "show ring coalesce" -d "Action"
complete -c wire -n "__fish_wire_using_command hw && test (count (commandline -opc)) -eq 4" -a "set" -d "Action"
complete -c wire -n "__fish_wire_using_command hw && test (count (commandline -opc)) -eq 5" -a "rx tx" -d "Direction"

# topology subcommands
complete -c wire -n "__fish_wire_using_command topology" -a "show path children help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand topology path && test (count (commandline -opc)) -eq 4" -a "to" -d "Keyword"

# diagnose subcommands
complete -c wire -n "__fish_wire_using_command diagnose" -a "ping trace capture help" -d "Action"

# trace subcommands
complete -c wire -n "__fish_wire_using_command trace" -a "(__fish_wire_interfaces)" -d "Interface"
complete -c wire -n "__fish_wire_using_command trace && test (count (commandline -opc)) -eq 3" -a "to" -d "Keyword"

# probe subcommands
complete -c wire -n "__fish_wire_using_command probe" -a "service help" -d "Action"
complete -c wire -n "__fish_wire_using_command probe && test (count (commandline -opc)) -eq 3" -a "scan ssh http https dns smtp" -d "Service"

# watch subcommands
complete -c wire -n "__fish_wire_using_command watch" -s i -l interval -d "Check interval"
complete -c wire -n "__fish_wire_using_command watch" -s t -l timeout -d "Timeout"
complete -c wire -n "__fish_wire_using_command watch" -s a -l alert -d "Alert on change"
complete -c wire -n "__fish_wire_using_command watch" -a help -d "Show help"

# apply subcommands
complete -c wire -n "__fish_wire_using_command apply" -F -d "Config file"
complete -c wire -n "__fish_wire_using_command apply" -l dry-run -d "Show changes without applying"
complete -c wire -n "__fish_wire_using_command apply" -l force -d "Force apply"
complete -c wire -n "__fish_wire_using_command apply" -l strict -d "Strict mode"
complete -c wire -n "__fish_wire_using_command apply" -l staging -d "Staging mode"
complete -c wire -n "__fish_wire_using_command apply" -s y -d "Auto-confirm"

# validate subcommands
complete -c wire -n "__fish_wire_using_command validate" -a "config vlan path service help" -d "Type"
complete -c wire -n "__fish_wire_using_command validate" -F -d "Config file"

# diff subcommands
complete -c wire -n "__fish_wire_using_command diff" -F -d "Config file"

# daemon subcommands
complete -c wire -n "__fish_wire_using_command daemon" -a "start stop status reload help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand daemon start" -F -d "Config file"

# history subcommands
complete -c wire -n "__fish_wire_using_command history" -a "show snapshot list diff log help" -d "Action"

# state subcommands
complete -c wire -n "__fish_wire_using_command state" -a "export help" -d "Action"
complete -c wire -n "__fish_wire_using_subcommand state export" -l interfaces-only -d "Export interfaces only"
complete -c wire -n "__fish_wire_using_subcommand state export" -l routes-only -d "Export routes only"
complete -c wire -n "__fish_wire_using_subcommand state export" -l all -d "Export all"
complete -c wire -n "__fish_wire_using_subcommand state export" -l no-comments -d "No comments"
