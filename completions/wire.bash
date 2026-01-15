#!/bin/bash
# wire bash completion script
# Install: cp wire.bash /etc/bash_completion.d/wire
# Or: source wire.bash

_wire_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cword=$COMP_CWORD

    local commands="interface route neighbor bond bridge vlan veth tunnel rule netns tc hw topology diagnose trace probe watch analyze apply validate diff state events daemon history"

    # First argument - main commands
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands --help --version -h -v" -- "$cur"))
        return
    fi

    local cmd="${COMP_WORDS[1]}"

    case "$cmd" in
        interface)
            if [[ $cword -eq 2 ]]; then
                local interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
                COMPREPLY=($(compgen -W "$interfaces" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "show set address delete stats" -- "$cur"))
            elif [[ $cword -eq 4 && "${COMP_WORDS[3]}" == "set" ]]; then
                COMPREPLY=($(compgen -W "state mtu mac" -- "$cur"))
            elif [[ $cword -eq 5 && "${COMP_WORDS[4]}" == "state" ]]; then
                COMPREPLY=($(compgen -W "up down" -- "$cur"))
            elif [[ $cword -eq 4 && "${COMP_WORDS[3]}" == "address" ]]; then
                COMPREPLY=($(compgen -W "del" -- "$cur"))
            fi
            ;;
        route)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "show add del default help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "add" ]]; then
                COMPREPLY=($(compgen -W "via dev default" -- "$cur"))
            fi
            ;;
        neighbor)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "show list lookup arp add del help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "add" ]]; then
                COMPREPLY=($(compgen -W "lladdr dev permanent" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "del" ]]; then
                COMPREPLY=($(compgen -W "dev" -- "$cur"))
            fi
            ;;
        bond)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "create delete add remove show help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "create" ]]; then
                COMPREPLY=($(compgen -W "mode miimon lacp_rate xmit_hash_policy" -- "$cur"))
            fi
            ;;
        bridge)
            if [[ $cword -eq 2 ]]; then
                local bridges=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')
                COMPREPLY=($(compgen -W "$bridges create delete add remove fdb help" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "show add remove fdb delete" -- "$cur"))
            fi
            ;;
        vlan)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "create delete show help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "create" ]]; then
                COMPREPLY=($(compgen -W "id on" -- "$cur"))
            fi
            ;;
        veth)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "peer delete show netns help" -- "$cur"))
            fi
            ;;
        tunnel)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "vxlan gre gretap geneve ipip sit wireguard delete help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "vxlan" ]]; then
                COMPREPLY=($(compgen -W "vni local group port learning nolearning" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "gre" || "${COMP_WORDS[2]}" == "gretap" ]]; then
                COMPREPLY=($(compgen -W "local remote key ttl" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "geneve" ]]; then
                COMPREPLY=($(compgen -W "id remote port ttl" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "ipip" || "${COMP_WORDS[2]}" == "sit" ]]; then
                COMPREPLY=($(compgen -W "local remote ttl" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "wireguard" ]]; then
                # WireGuard just needs interface name
                COMPREPLY=()
            fi
            ;;
        rule)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "show list add del help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "add" ]]; then
                COMPREPLY=($(compgen -W "from to fwmark table prio iif oif blackhole unreachable prohibit" -- "$cur"))
            fi
            ;;
        netns|namespace)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "list show add create del delete exec set help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "exec" ]]; then
                if [[ $cword -eq 3 ]]; then
                    local namespaces=$(ls /var/run/netns 2>/dev/null)
                    COMPREPLY=($(compgen -W "$namespaces" -- "$cur"))
                elif [[ $cword -eq 4 ]]; then
                    # Suggest common commands to run in namespace
                    COMPREPLY=($(compgen -W "wire ip ss ping iptables nft bash sh" -- "$cur"))
                fi
            elif [[ "${COMP_WORDS[2]}" == "del" || "${COMP_WORDS[2]}" == "delete" || "${COMP_WORDS[2]}" == "set" ]]; then
                if [[ $cword -eq 3 ]]; then
                    local namespaces=$(ls /var/run/netns 2>/dev/null)
                    COMPREPLY=($(compgen -W "$namespaces" -- "$cur"))
                elif [[ "${COMP_WORDS[2]}" == "set" && $cword -eq 4 ]]; then
                    local namespaces=$(ls /var/run/netns 2>/dev/null)
                    COMPREPLY=($(compgen -W "$namespaces" -- "$cur"))
                fi
            elif [[ "${COMP_WORDS[2]}" == "add" || "${COMP_WORDS[2]}" == "create" ]]; then
                # No completion for new namespace name
                COMPREPLY=()
            fi
            ;;
        tc|qdisc)
            if [[ $cword -eq 2 ]]; then
                local interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
                COMPREPLY=($(compgen -W "$interfaces help" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "show add del class filter" -- "$cur"))
            elif [[ $cword -eq 4 && "${COMP_WORDS[3]}" == "add" ]]; then
                COMPREPLY=($(compgen -W "pfifo fq_codel tbf htb" -- "$cur"))
            elif [[ "${COMP_WORDS[4]}" == "tbf" ]]; then
                COMPREPLY=($(compgen -W "rate burst latency" -- "$cur"))
            elif [[ "${COMP_WORDS[4]}" == "pfifo" ]]; then
                COMPREPLY=($(compgen -W "limit" -- "$cur"))
            elif [[ "${COMP_WORDS[4]}" == "htb" ]]; then
                COMPREPLY=($(compgen -W "default" -- "$cur"))
            elif [[ "${COMP_WORDS[3]}" == "class" ]]; then
                if [[ $cword -eq 4 ]]; then
                    COMPREPLY=($(compgen -W "show add del" -- "$cur"))
                elif [[ $cword -ge 5 && "${COMP_WORDS[4]}" == "add" ]]; then
                    COMPREPLY=($(compgen -W "rate ceil prio" -- "$cur"))
                fi
            elif [[ "${COMP_WORDS[3]}" == "filter" ]]; then
                if [[ $cword -eq 4 ]]; then
                    COMPREPLY=($(compgen -W "show add del" -- "$cur"))
                elif [[ $cword -eq 5 && "${COMP_WORDS[4]}" == "add" ]]; then
                    COMPREPLY=($(compgen -W "u32 fw" -- "$cur"))
                elif [[ "${COMP_WORDS[5]}" == "u32" ]]; then
                    COMPREPLY=($(compgen -W "match flowid" -- "$cur"))
                elif [[ "${COMP_WORDS[5]}" == "fw" ]]; then
                    COMPREPLY=($(compgen -W "handle classid" -- "$cur"))
                fi
            fi
            ;;
        hw|hardware)
            if [[ $cword -eq 2 ]]; then
                local interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
                COMPREPLY=($(compgen -W "$interfaces help" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "show ring coalesce" -- "$cur"))
            elif [[ $cword -eq 4 && ("${COMP_WORDS[3]}" == "ring" || "${COMP_WORDS[3]}" == "coalesce") ]]; then
                COMPREPLY=($(compgen -W "set" -- "$cur"))
            elif [[ "${COMP_WORDS[4]}" == "set" ]]; then
                COMPREPLY=($(compgen -W "rx tx" -- "$cur"))
            fi
            ;;
        topology)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "show path children help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "path" && $cword -eq 4 ]]; then
                COMPREPLY=($(compgen -W "to" -- "$cur"))
            fi
            ;;
        diagnose)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "ping trace capture help" -- "$cur"))
            fi
            ;;
        trace)
            if [[ $cword -eq 2 ]]; then
                local interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
                COMPREPLY=($(compgen -W "$interfaces" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "to" -- "$cur"))
            fi
            ;;
        probe)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "service help" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                COMPREPLY=($(compgen -W "scan ssh http https dns smtp" -- "$cur"))
            fi
            ;;
        watch)
            COMPREPLY=($(compgen -W "--interval --timeout --alert -i -t -a help" -- "$cur"))
            ;;
        apply)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -f -- "$cur"))
            else
                COMPREPLY=($(compgen -W "--dry-run --force --strict --staging -y" -- "$cur"))
            fi
            ;;
        validate)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "config vlan path service help" -- "$cur"))
                COMPREPLY+=($(compgen -f -- "$cur"))
            fi
            ;;
        diff)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -f -- "$cur"))
            fi
            ;;
        daemon)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "start stop status reload help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "start" ]]; then
                COMPREPLY=($(compgen -f -- "$cur"))
            fi
            ;;
        history)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "show snapshot list diff log help" -- "$cur"))
            fi
            ;;
        state)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "export help" -- "$cur"))
            elif [[ "${COMP_WORDS[2]}" == "export" ]]; then
                COMPREPLY=($(compgen -W "--interfaces-only --routes-only --all --no-comments" -- "$cur"))
            fi
            ;;
    esac
}

complete -F _wire_completions wire
