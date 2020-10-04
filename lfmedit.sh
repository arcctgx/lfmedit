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
    echo "  -d              increase level of debug prints"
    echo "  -h              display this help message"
    echo
    echo "Parameters -u and at least one of -t/-a/-b/-z are mandatory."
    echo "Use -Z to override the assumption that original album artist"
    echo "is the same as original track artist in case it's not."
    echo

    exit 1
}

checkMandatoryParameters() {
    if [ ! -v timestamp ] || [ -z "${timestamp}" ]; then
        logError "Unix timestamp (-u) must be provided!"
        return 1
    fi

    if [ ! -v newTitle ] && [ ! -v newArtist ] && [ ! -v newAlbum ] && [ ! -v newAlbumArtist ] ; then
        logError "At least one of -t/-a/-b/-z parameters must be provided!"
        return 1
    fi

    return 0
}

parseArguments() {
    while getopts ":u:t:a:b:z:Z:dh" options; do
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
            d)
                ((debugLevel++))
                ;;
            h)
                usage
                ;;
            *)
                # quietly ignore unsupported options
                ;;
        esac
    done

    if [ "${debugLevel}" -ge 2 ]; then
        verbose="--verbose"
        silent=""
    else
        verbose=""
        silent="--silent"
    fi

    logDebug "args = ${*}"

    if ! checkMandatoryParameters; then
        logError "Missing mandatory parameters!"
        echo
        usage
    fi
}

main() {
    parseArguments "${@}"
    checkAuthTokens
    requestOriginalScrobbleData
    extractOriginalScrobbleData
    requestScrobbleEdit
    verifyScrobbleEdit
}

main "${@}"
