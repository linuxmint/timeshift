# bash completion for timeshift

_timeshift_snapshots()
{
    timeshift --list 2>/dev/null \
    | awk '
        /^-+$/ { table=1; next }
        table && NF >= 3 { print $3 }
    '
}

_timeshift()
{
    local cur prev opts snaps
    COMPREPLY=()

    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    opts='
        --list
        --list-snapshots
        --list-devices

        --check
        --create
        --comments
        --tags

        --restore
        --snapshot
        --target
        --target-device
        --grub
        --grub-device
        --skip-grub

        --delete
        --delete-all

        --snapshot-device
        --yes
        --btrfs
        --rsync
        --debug
        --verbose
        --quiet
        --scripted
        --help
        --version
    '

    case "$prev" in
        --comments|--target|--target-device|--grub|--grub-device|--snapshot-device)
            return 0
            ;;
        --tags)
            COMPREPLY=( $(compgen -W 'O B H D W M' -- "$cur") )
            return 0
            ;;
        --snapshot)
            COMPREPLY=()
            while IFS= read -r s; do
                COMPREPLY+=( "$(printf '%q' "$s")" )
            done < <(
                compgen -W "$(_timeshift_snapshots)" -- "$cur"
            )
            return 0
            ;;

#            snaps=$(_timeshift_snapshots)
#            COMPREPLY=( $(compgen -W "$snaps" -- "$cur") )
#            return 0
#            ;;
    esac

    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
}

complete -F _timeshift timeshift
