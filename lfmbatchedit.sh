#!/bin/bash

source "utils.sh"
source "scrobble_edit.sh"

usage() {
    echo "usage: $(basename "$0") [options] <file> [file2 ...]"
    echo
    echo "Available options:"
    echo
    echo "  -n  dry run: print edits, but do not apply them"
    echo "  -Y  do not ask to confirm an edit (ignored when -n is used)"
    echo "  -V  enable verification of edits"
    echo "  -d  increase level of debug prints"
    echo "  -h  display this help message"
    echo
    echo "Input files are diffs of last.fm library export files"
    echo "compatible with the format used by lastscrape tool."
    echo
}

parseArguments() {
    while getopts ":nYVdh" options; do
        case "${options}" in
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
                logDebug "Verification of edits is enabled."
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

    shift $((OPTIND-1))
    fileList="${*}"
    logDebug "file list = ${fileList}"

    if [[ ${*} == "" ]]; then
        logError "Missing mandatory parameters!"
        echo
        usage
        return 1
    fi
}

logAppliedEdit() {
    dateStr=$(date -Iseconds)
    echo -e "${dateStr}\t+${timestamp}\t${newTitle}\t${newArtist}\t${newAlbum}" >> applied.log
}

logFailedEdit() {
    if [[ ! -v dryRun || "${dryRun}" != "yes" ]]; then
        dateStr=$(date -Iseconds)
        echo -e "${dateStr}\t+${timestamp}\t${newTitle}\t${newArtist}\t${newAlbum}" >> failed.log
    fi
}

applyChangesFrom() {
    local -r file="${1}"
    local -r nChange=$(grep -c -E "^\+[0-9]{10}" "${file}")
    local n=0

    local -r timeStart=$(date +%s)

    grep -E "^\+[0-9]{10}" "${file}" | sed "s/^+//" | tr '\011' '\037' |
        while IFS=$'\037' read -r -a scrobble; do
            ((n++))
            unset -v originalAlbumArtist newAlbumArtist

            echo
            logInfo "editing scrobble ${n} of ${nChange}"

            timestamp="${scrobble[0]}"
            newTitle="${scrobble[1]}"
            newArtist="${scrobble[2]}"
            newAlbum="${scrobble[3]}"

            logDebug "timestamp = ${timestamp}, newTitle = ${newTitle}, newArtist = ${newArtist}, newAlbum = ${newAlbum}"

            if ! requestOriginalScrobbleData; then
                logFailedEdit
                continue
            fi

            if ! readOriginalScrobbleData; then
                logFailedEdit
                continue
            fi

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

        echo
        logInfo "Processed ${nChange} scrobbles from \"${file}\" in $(($(date +%s)-timeStart)) seconds."
}

processFiles() {
    local f

    for f in ${fileList}; do
        logInfo "processing \"${f}\""
        applyChangesFrom "${f}"
    done
}

main() {
    parseArguments "${@}" || exit 1
    checkAuthTokens || exit 2
    processFiles
}

main "${@}"
