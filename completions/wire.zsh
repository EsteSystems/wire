#compdef wire
# wire zsh completion script
# Install: cp wire.zsh /usr/share/zsh/site-functions/_wire
# Or add to fpath: fpath=(~/.zsh/completions $fpath)

_wire_interfaces() {
    local interfaces
    interfaces=(${(f)"$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)"})
    _describe -t interfaces 'interface' interfaces
}

_wire_namespaces() {
    local namespaces
    namespaces=(${(f)"$(ls /var/run/netns 2>/dev/null)"})
    _describe -t namespaces 'namespace' namespaces
}

_wire_bridges() {
    local bridges
    bridges=(${(f)"$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')"})
    _describe -t bridges 'bridge' bridges
}

_wire_interface() {
    local -a actions
    actions=(
        'show:Show interface details'
        'set:Set interface property'
        'address:Manage addresses'
        'delete:Delete interface'
        'stats:Show interface statistics'
    )

    case $words[3] in
        set)
            local -a props
            props=('state:Set up/down' 'mtu:Set MTU' 'mac:Set MAC address')
            _describe -t props 'property' props
            ;;
        address)
            _values 'action' 'del[Delete address]'
            ;;
        *)
            if (( CURRENT == 3 )); then
                _wire_interfaces
            elif (( CURRENT == 4 )); then
                _describe -t actions 'action' actions
            fi
            ;;
    esac
}

_wire_route() {
    local -a actions
    actions=(
        'show:Show routes'
        'add:Add route'
        'del:Delete route'
        'default:Default route'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "add" ]]; then
        _values 'option' 'via[Gateway]' 'dev[Device]' 'default[Default route]'
    fi
}

_wire_neighbor() {
    local -a actions
    actions=(
        'show:Show neighbors'
        'list:List neighbors'
        'lookup:Lookup neighbor'
        'arp:Show ARP table'
        'add:Add neighbor'
        'del:Delete neighbor'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "add" ]]; then
        _values 'option' 'lladdr[Link-layer address]' 'dev[Device]' 'permanent[Permanent entry]'
    elif [[ $words[3] == "del" ]]; then
        _values 'option' 'dev[Device]'
    fi
}

_wire_bond() {
    local -a actions
    actions=(
        'create:Create bond'
        'delete:Delete bond'
        'add:Add member'
        'remove:Remove member'
        'show:Show bond'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "create" ]]; then
        _values 'option' \
            'mode[Bond mode]' \
            'miimon[MII monitoring interval]' \
            'lacp_rate[LACP rate]' \
            'xmit_hash_policy[Hash policy]'
    fi
}

_wire_bridge() {
    local -a actions
    actions=(
        'create:Create bridge'
        'delete:Delete bridge'
        'add:Add port'
        'remove:Remove port'
        'fdb:Show forwarding database'
        'show:Show bridge'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _wire_bridges
        _describe -t actions 'action' actions
    elif (( CURRENT == 4 )); then
        _describe -t actions 'action' actions
    fi
}

_wire_vlan() {
    local -a actions
    actions=(
        'create:Create VLAN'
        'delete:Delete VLAN'
        'show:Show VLAN'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "create" ]]; then
        _values 'option' 'id[VLAN ID]' 'on[Parent interface]'
    fi
}

_wire_veth() {
    local -a actions
    actions=(
        'peer:Create veth pair'
        'delete:Delete veth'
        'show:Show veth info'
        'netns:Move to namespace'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    fi
}

_wire_tunnel() {
    local -a types
    types=(
        'vxlan:VXLAN tunnel'
        'gre:GRE tunnel'
        'gretap:GRE TAP tunnel'
        'geneve:GENEVE tunnel'
        'ipip:IP-in-IP tunnel'
        'sit:SIT tunnel (IPv6 over IPv4)'
        'wireguard:WireGuard tunnel'
        'delete:Delete tunnel'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t types 'type' types
    else
        case $words[3] in
            vxlan)
                _values 'option' 'vni[VNI]' 'local[Local IP]' 'group[Multicast group]' 'port[UDP port]' 'learning' 'nolearning'
                ;;
            gre|gretap)
                _values 'option' 'local[Local IP]' 'remote[Remote IP]' 'key[Key]' 'ttl[TTL]'
                ;;
            geneve)
                _values 'option' 'id[VNI]' 'remote[Remote IP]' 'port[UDP port]' 'ttl[TTL]'
                ;;
            ipip|sit)
                _values 'option' 'local[Local IP]' 'remote[Remote IP]' 'ttl[TTL]'
                ;;
        esac
    fi
}

_wire_rule() {
    local -a actions
    actions=(
        'show:Show rules'
        'list:List rules'
        'add:Add rule'
        'del:Delete rule'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "add" ]]; then
        _values 'option' \
            'from[Source prefix]' \
            'to[Destination prefix]' \
            'fwmark[Firewall mark]' \
            'table[Routing table]' \
            'prio[Priority]' \
            'iif[Input interface]' \
            'oif[Output interface]' \
            'blackhole' \
            'unreachable' \
            'prohibit'
    fi
}

_wire_netns() {
    local -a actions
    actions=(
        'list:List namespaces'
        'show:Show namespace'
        'add:Create namespace'
        'create:Create namespace'
        'del:Delete namespace'
        'delete:Delete namespace'
        'exec:Execute in namespace'
        'set:Move interface to namespace'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "exec" ]]; then
        if (( CURRENT == 4 )); then
            _wire_namespaces
        elif (( CURRENT == 5 )); then
            _values 'command' 'wire' 'ip' 'ss' 'ping' 'iptables' 'nft' 'bash' 'sh'
        fi
    elif [[ $words[3] == "del" || $words[3] == "delete" ]]; then
        _wire_namespaces
    elif [[ $words[3] == "set" ]]; then
        if (( CURRENT == 4 )); then
            _wire_interfaces
        elif (( CURRENT == 5 )); then
            _wire_namespaces
        fi
    fi
}

_wire_tc() {
    local -a actions
    actions=(
        'show:Show qdiscs'
        'add:Add qdisc'
        'del:Delete qdisc'
        'class:Manage classes'
        'filter:Manage filters'
    )

    if (( CURRENT == 3 )); then
        _wire_interfaces
    elif (( CURRENT == 4 )); then
        _describe -t actions 'action' actions
    elif [[ $words[4] == "add" ]]; then
        _values 'qdisc' 'pfifo[Packet FIFO]' 'fq_codel[Fair Queue CoDel]' 'tbf[Token Bucket Filter]' 'htb[Hierarchical Token Bucket]'
    elif [[ $words[4] == "class" ]]; then
        if (( CURRENT == 5 )); then
            _values 'action' 'show[Show classes]' 'add[Add class]' 'del[Delete class]'
        elif [[ $words[5] == "add" ]]; then
            _values 'option' 'rate[Rate limit]' 'ceil[Ceiling rate]' 'prio[Priority]'
        fi
    elif [[ $words[4] == "filter" ]]; then
        if (( CURRENT == 5 )); then
            _values 'action' 'show[Show filters]' 'add[Add filter]' 'del[Delete filter]'
        elif [[ $words[5] == "add" ]]; then
            _values 'type' 'u32[U32 filter]' 'fw[Firewall mark filter]'
        fi
    fi
}

_wire_hw() {
    local -a actions
    actions=(
        'show:Show hardware info'
        'ring:Ring buffer settings'
        'coalesce:Interrupt coalescing'
    )

    if (( CURRENT == 3 )); then
        _wire_interfaces
    elif (( CURRENT == 4 )); then
        _describe -t actions 'action' actions
    elif [[ $words[4] == "ring" || $words[4] == "coalesce" ]]; then
        if (( CURRENT == 5 )); then
            _values 'action' 'set[Set values]'
        elif (( CURRENT == 6 )); then
            _values 'direction' 'rx[Receive]' 'tx[Transmit]'
        fi
    fi
}

_wire_topology() {
    local -a actions
    actions=(
        'show:Show topology'
        'path:Find path'
        'children:Show children'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "path" && CURRENT == 5 ]]; then
        _values 'keyword' 'to[Destination]'
    fi
}

_wire_diagnose() {
    local -a actions
    actions=(
        'ping:Ping test'
        'trace:Trace route'
        'capture:Packet capture'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    fi
}

_wire_trace() {
    if (( CURRENT == 3 )); then
        _wire_interfaces
    elif (( CURRENT == 4 )); then
        _values 'keyword' 'to[Destination]'
    fi
}

_wire_probe() {
    local -a actions
    actions=(
        'service:Probe service'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif (( CURRENT == 4 )); then
        _values 'service' 'scan' 'ssh' 'http' 'https' 'dns' 'smtp'
    fi
}

_wire_watch() {
    _arguments \
        '-i[Check interval]:interval' \
        '--interval[Check interval]:interval' \
        '-t[Timeout]:timeout' \
        '--timeout[Timeout]:timeout' \
        '-a[Alert threshold]:threshold' \
        '--alert[Alert threshold]:threshold' \
        'help:Show help'
}

_wire_apply() {
    _arguments \
        '--dry-run[Show changes without applying]' \
        '--force[Force apply]' \
        '--strict[Strict mode]' \
        '--staging[Staging mode]' \
        '-y[Auto-confirm]' \
        '*:config file:_files'
}

_wire_validate() {
    local -a types
    types=(
        'config:Validate config file'
        'vlan:Validate VLAN'
        'path:Validate path'
        'service:Validate service'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t types 'type' types
        _files
    fi
}

_wire_daemon() {
    local -a actions
    actions=(
        'start:Start daemon'
        'stop:Stop daemon'
        'status:Show status'
        'reload:Reload config'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "start" ]]; then
        _files
    fi
}

_wire_history() {
    local -a actions
    actions=(
        'show:Show history'
        'snapshot:Create snapshot'
        'list:List snapshots'
        'diff:Show diff'
        'log:Show log'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    fi
}

_wire_state() {
    local -a actions
    actions=(
        'export:Export state'
        'help:Show help'
    )

    if (( CURRENT == 3 )); then
        _describe -t actions 'action' actions
    elif [[ $words[3] == "export" ]]; then
        _arguments \
            '--interfaces-only[Export interfaces only]' \
            '--routes-only[Export routes only]' \
            '--all[Export all]' \
            '--no-comments[No comments]'
    fi
}

_wire() {
    local -a commands
    commands=(
        'interface:Interface management'
        'route:Routing table'
        'neighbor:ARP/NDP table'
        'bond:Bond interface management'
        'bridge:Bridge interface management'
        'vlan:VLAN interface management'
        'veth:Veth pair management'
        'tunnel:Tunnel management'
        'rule:IP policy routing rules'
        'netns:Network namespace management'
        'tc:Traffic control (qdiscs)'
        'hw:Hardware tuning (ethtool)'
        'topology:Show network topology'
        'diagnose:Network diagnostics'
        'trace:Trace path to destination'
        'probe:Test TCP connectivity'
        'watch:Continuous monitoring'
        'analyze:Analyze network configuration'
        'apply:Apply configuration file'
        'validate:Validate configuration'
        'diff:Compare config vs live state'
        'state:Show current network state'
        'events:Monitor network events'
        'daemon:Supervision daemon control'
        'history:Change history and snapshots'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'command' commands
        _arguments \
            '-h[Show help]' \
            '--help[Show help]' \
            '-v[Show version]' \
            '--version[Show version]'
    else
        case $words[2] in
            interface) _wire_interface ;;
            route) _wire_route ;;
            neighbor) _wire_neighbor ;;
            bond) _wire_bond ;;
            bridge) _wire_bridge ;;
            vlan) _wire_vlan ;;
            veth) _wire_veth ;;
            tunnel) _wire_tunnel ;;
            rule) _wire_rule ;;
            netns|namespace) _wire_netns ;;
            tc|qdisc) _wire_tc ;;
            hw|hardware) _wire_hw ;;
            topology) _wire_topology ;;
            diagnose) _wire_diagnose ;;
            trace) _wire_trace ;;
            probe) _wire_probe ;;
            watch) _wire_watch ;;
            apply) _wire_apply ;;
            validate) _wire_validate ;;
            diff) _files ;;
            daemon) _wire_daemon ;;
            history) _wire_history ;;
            state) _wire_state ;;
        esac
    fi
}

_wire "$@"
