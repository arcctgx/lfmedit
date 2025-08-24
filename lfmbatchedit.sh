#!/bin/bash

source "utils.sh"
source "scrobble_edit.sh"

editDelaySec="${LFMEDIT_EDIT_DELAY_SEC:-0.5}"

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
                # verification doubles the number of requests per edit, so double the delay too:
                editDelaySec="$(echo "2*${editDelaySec}" | bc -l)"
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

    logDebug "edit delay: ${editDelaySec} seconds"
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

makeLogEntry() {
    local -r dateStr=$(date -Iseconds)
    local -r originalData="${timestamp}\t${originalTitle}\t${originalArtist}\t${originalAlbum}"
    local -r newData="${newTimestamp}\t${newTitle}\t${newArtist}\t${newAlbum}"
    echo -e "${dateStr}\t${originalData}\t${newData}"
}

logAppliedEdit() {
    makeLogEntry >> applied.log
}

logFailedEdit() {
    if [[ ! -v dryRun || "${dryRun}" != "yes" ]]; then
        makeLogEntry >> failed.log
    fi
}

applyChangesFrom() {
    local -r file="${1}"
    local -r nChange=$(wc -l "${file}" | awk '{print $1}')
    local n=0
    local remaining=${nChange}

    local -r timeStart=$(date +%s)

    tr '\011' '\037' < "${file}" |
        while IFS=$'\037' read -r -a scrobble; do
            ((n++))
            ((remaining--))
            unset -v originalAlbumArtist newAlbumArtist

            echo
            logInfo "editing scrobble ${n} of ${nChange}"

            timestamp="${scrobble[0]}"
            originalTitle="${scrobble[1]}"
            originalArtist="${scrobble[2]}"
            originalAlbum="${scrobble[3]}"
            newTimestamp="${scrobble[4]}"
            newTitle="${scrobble[5]}"
            newArtist="${scrobble[6]}"
            newAlbum="${scrobble[7]}"

            logDebug "timestamp = ${timestamp}, originalTitle = ${originalTitle}, originalArtist = ${originalArtist}, originalAlbum = ${originalAlbum}"
            logDebug "newTimestamp = ${newTimestamp}, newTitle = ${newTitle}, newArtist = ${newArtist}, newAlbum = ${newAlbum}"

            if [[ ${newTimestamp} -ne ${timestamp} ]]; then
                logError "Timestamp mismatch in scrobble ${n}: ${timestamp} vs. ${newTimestamp}, aborting!"
                exit 3
            fi

            # originalAlbumArtist is likely always unset when this function
            # is called because lfmbatchedit does not support -Z option.
            handleAlbumArtist

            if ! requestScrobbleEdit; then
                logFailedEdit
                continue
            fi

            if ! verifyScrobbleEdit; then
                logFailedEdit
                continue
            fi

            logAppliedEdit

            if [[ ! -v dryRun ]] || [[ "${dryRun}" != "yes" ]] && [[ ${remaining} -ne 0 ]]; then
                logDebug "waiting ${editDelaySec} seconds..."
                sleep "${editDelaySec}s"
            fi
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
