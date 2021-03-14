#!/bin/bash

source "utils.sh"
source "scrobble_edit.sh"

usage() {
    echo "usage: $(basename "$0") <parameters>"
    echo
    echo "List of parameters:"
    echo
    echo "  -u <timestamp>  Unix timestamp of scrobble to edit"
    echo "  -t <string>     new track title"
    echo "  -a <string>     new artist name"
    echo "  -b <string>     new album title"
    echo "  -z <string>     new album artist name"
    echo "  -Z <string>     original album artist name"
    echo "  -n              dry run: print edits, but do not apply them"
    echo "  -Y              do not ask to confirm an edit (ignored when -n is used)"
    echo "  -V              enable edit verification"
    echo "  -d              increase level of debug prints"
    echo "  -h              display this help message"
    echo
    echo "Parameters -u and at least one of -t/-a/-b/-z are mandatory."
    echo "Use -Z to override the assumption that original album artist"
    echo "is the same as original track artist in case it's not."
    echo
}

checkMandatoryParameters() {
    if [[ ! -v timestamp  ||  -z "${timestamp}" ]]; then
        logError "Unix timestamp (-u) must be provided!"
        return 1
    fi

    if [[ ! -v newTitle && ! -v newArtist && ! -v newAlbum && ! -v newAlbumArtist ]]; then
        logError "At least one of -t/-a/-b/-z parameters must be provided!"
        return 2
    fi
}

parseArguments() {
    while getopts ":u:t:a:b:z:Z:nYVdh" options; do
        case "${options}" in
            u)
                timestamp="${OPTARG}"
                ;;
            t)
                newTitle="${OPTARG}"
                ;;
            a)
                newArtist="${OPTARG}"
                ;;
            b)
                newAlbum="${OPTARG}"
                ;;
            z)
                newAlbumArtist="${OPTARG}"
                ;;
            Z)
                originalAlbumArtist="${OPTARG}"
                ;;
            n)
                dryRun="yes"
                logDebug "Dry run, changes will not be applied."
                ;;
            Y)
                dontAsk="yes"
                logDebug "Asking for edit confirmation is disabled."
                ;;
            V)
                enableVerification="yes"
                logDebug "Edit verification is enabled."
                ;;
            d)
                ((debugLevel++))
                ;;
            h)
                usage && exit 0
                ;;
            *)
                # quietly ignore unsupported options
                ;;
        esac
    done

    if [[ ${debugLevel} -ge 2 ]]; then
        verbose="--verbose"
        silent=""
    else
        verbose=""
        silent="--silent"
    fi

    if [[ ${debugLevel} -ge 3 ]]; then
        set -x
    fi

    logDebug "args = ${*}"

    if ! checkMandatoryParameters; then
        logError "Missing mandatory parameters!"
        echo
        usage
        return 1
    fi
}

main() {
    parseArguments "${@}" || exit 1
    checkAuthTokens || exit 2
    requestOriginalScrobbleData || exit 3
    readOriginalScrobbleData || exit 4
    requestScrobbleEdit || exit 5
    verifyScrobbleEdit || exit 6
}

main "${@}"
