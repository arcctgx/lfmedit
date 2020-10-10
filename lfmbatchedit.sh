#!/bin/bash

source "utils.sh"
source "scrobble_edit.sh"

usage() {
    echo "usage: $(basename "$0") [-d] <file> [file2 ...]"
    echo
    echo "  -n  dry run: print edits, but do not apply them"
    echo "  -Y  do not ask to confirm an edit (ignored when -n is used)"
    echo "  -d  increase level of debug prints"
    echo "  -h  display this help message"
    echo
    echo "Input files are diffs of last.fm library export files"
    echo "compatible with the format used by lastscrape tool."
    echo
}

parseArguments() {
    while getopts ":nYdh" options; do
        case "${options}" in
            n)
                dryRun="yes"
                ;;
            Y)
                dontAsk="yes"
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

    if [ "${debugLevel}" -ge 2 ]; then
        verbose="--verbose"
        silent=""
    else
        verbose=""
        silent="--silent"
    fi

    logDebug "args = ${*}"

    shift $((OPTIND-1))
    fileList="${*}"
    logDebug "file list = ${fileList}"

    if [[ ${*} == "" ]]; then
        logError "Missing mandatory parameters!"
        echo
        usage
    fi
}

logAppliedEdit() {
    dateStr=$(date -Iseconds)
    echo -e "${dateStr}\t+${timestamp}\t${newTitle}\t${newArtist}\t${newAlbum}" >> applied.log
}

logFailedEdit() {
    if [[ ! -v dryRun || $dryRun != "yes" ]]; then
        dateStr=$(date -Iseconds)
        echo -e "${dateStr}\t+${timestamp}\t${newTitle}\t${newArtist}\t${newAlbum}" >> failed.log
    fi
}

applyChangesFrom() {
    local -r file="${1}"
    local -r nChange=$(grep -c -E "^\+[0-9]{10}" "${file}")
    local n=0

    grep -E "^\+[0-9]{10}" "${file}" | sed "s/^+//" |
        while IFS=$'\t' read -r -a scrobble; do
            ((n++))
            unset -v timestamp newTitle newArtist newAlbum newAlbumArtist

            logInfo "editing scrobble ${n} of ${nChange}"

            timestamp="${scrobble[0]}"

            if ! requestOriginalScrobbleData; then
                logFailedEdit
                continue
            fi

            if ! extractOriginalScrobbleData; then
                logFailedEdit
                continue
            fi

            newTitle="${scrobble[1]}"
            newArtist="${scrobble[2]}"
            newAlbum="${scrobble[3]}"

            logDebug "timestamp = ${timestamp}, newTitle = ${newTitle}, newArtist = ${newArtist}, newAlbum = ${newAlbum}"

            if ! requestScrobbleEdit; then
                logFailedEdit
                continue
            fi

            if ! verifyScrobbleEdit; then
                logFailedEdit
                continue
            fi

            logAppliedEdit
        done
}

processFiles() {
    local f

    for f in ${fileList}; do
        logInfo "processing \"${f}\""
        applyChangesFrom "${f}"
    done
}

main() {
    parseArguments "${@}"
    checkAuthTokens
    processFiles
}

main "${@}"
