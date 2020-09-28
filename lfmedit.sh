#!/bin/bash

logDebug() {
    if [ "${debugLevel}" -ge 1 ]; then
        echo -e "\e[90mDBG: ${FUNCNAME[1]}(): ${*}\e[0m"
    fi
}

logInfo() {
    echo "INF: ${FUNCNAME[1]}(): ${*}"
}

logWarning() {
    echo -e "\e[33mWRN: ${FUNCNAME[1]}(): ${*}\e[0m"
}

logError() {
    echo -e "\e[31mERR: ${FUNCNAME[1]}(): ${*}\e[0m"
}

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
    debugLevel=0

    while getopts ":u:t:a:b:z:Z:d" options; do
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

checkAuthTokens() {
    if [ -f auth_tokens ]; then
        logDebug "reading auth_tokens file"
        . auth_tokens
    fi

    if [ -z "${LASTFM_USERNAME}" ]; then
        logError "last.fm username not provided, exiting!"
        exit 1
    elif [ -z "${LASTFM_SESSION_ID}" ]; then
        logError "last.fm session ID is not provided, exiting!"
        exit 1
    elif [ -z "${LASTFM_CSRF}" ]; then
        logError "last.fm CSRF token is not provided, exiting!"
        exit 1
    fi

    logInfo "all necessary authentication tokens are set"
}

handleApiErrors() {
    # TODO parse response to detect API errors
    false
}

requestOriginalScrobbleData() {
    apiResponsePath="$(mktemp -t lfmquery.json.XXXXXX)"
    logDebug "apiResponsePath = ${apiResponsePath}"

    local -r apiRoot="http://ws.audioscrobbler.com/2.0/"
    local -r apiKey="29a5d6e1ddfce0e472ce9a328ac21ff5"
    local -r timeFrom="${timestamp}"
    local -r timeTo=$((timeFrom+1))     # a hack to limit results to a single scrobble
    local -r perPage=1                  # request one scrobble per page...
    local -r page=1                     # ...and only the first page of results.
    local url=""

    logDebug "username = ${LASTFM_USERNAME}, timeFrom = ${timeFrom}, timeTo = ${timeTo}"

    url+="${apiRoot}?method=user.getrecenttracks&api_key=${apiKey}"
    url+="&user=${LASTFM_USERNAME}"
    url+="&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}&format=json"

    curl ${silent} -o "${apiResponsePath}" "${url}"
    local -r curlStatus="${?}"

    if [ ${curlStatus} -ne 0 ]; then
        logError "failed to send last.fm API request! curl error = ${curlStatus}"
        rm -f "${verbose}" "${apiResponsePath}"
        exit 2
    fi

    handleApiErrors

    if [ "${debugLevel}" -ge 2 ]; then
        jq --monochrome-output . "${apiResponsePath}"
    fi
}

extractOriginalScrobbleData() {
    # We expect that there are at most two tracks in the response:
    # "now playing" (optional), and the one we want (always last).
    # The attribute "total" holds the number of returned scrobbles,
    # excluding "now playing" one. This should be equal to one.
    local -r total=$(jq -r '.recenttracks."@attr".total' "${apiResponsePath}")
    logDebug "total = ${total}"
    if [ "${total}" -ne 1 ]; then
        logError "unexpected number of scrobbles in API response! (got ${total} instead of 1)"
        rm -f "${verbose}" "${apiResponsePath}"
        exit 4
    fi

    # Compare timestamps to make sure we got the scrobble we wanted.
    local -r uts=$(jq -r '.recenttracks.track[-1].date.uts' "${apiResponsePath}")
    if [ "${uts}" -eq "${timestamp}" ]; then
        logDebug "got scrobble with matching timestamp: uts = $uts"
    else
        logError "scrobble timestamp mismatch! (expected: ${timestamp}, received: ${uts})"
        rm -f "${verbose}" "${apiResponsePath}"
        exit 4
    fi

    originalTitle=$(jq -r '.recenttracks.track[-1].name' "${apiResponsePath}")
    originalArtist=$(jq -r '.recenttracks.track[-1].artist["#text"]' "${apiResponsePath}")
    originalAlbum=$(jq -r '.recenttracks.track[-1].album["#text"]' "${apiResponsePath}")
    logDebug "originalTitle = ${originalTitle}, originalArtist = ${originalArtist}, originalAlbum = ${originalAlbum}"

    # There's no way to get original album artist from last.fm API.
    # In most cases this will be the same as track artist.
    if [ ! -v originalAlbumArtist ]; then
        logDebug "assuming original album artist is the same as original track artist"
        originalAlbumArtist="${originalArtist}"
    fi

    # If there's no original album, then original album artist must be blank too.
    if [ -z "${originalAlbum}" ]; then
        logDebug "no original album set for scrobble, assuming empty original album artist."
        originalAlbumArtist=""
    fi

    logDebug "originalAlbumArtist = ${originalAlbumArtist}"

    rm -f "${verbose}" "${apiResponsePath}"
}

urlEncode() {
    local LANG=C i c e=''

    for (( i=0 ; i<${#1} ; i++ )); do
        c=${1:$i:1}
        [[ "$c" =~ [a-zA-Z0-9\.\~\_\-] ]] || printf -v c '%%%02X' "'$c"
        e+="$c"
    done

    echo "$e"
}

setNewScrobbleData() {
    if [ ! -v newTitle ]; then
        newTitle="${originalTitle}"
    fi

    if [ ! -v newArtist ]; then
        newArtist="${originalArtist}"
    fi

    if [ ! -v newAlbum ]; then
        newAlbum="${originalAlbum}"
    fi

    # TODO move new album artist logic to a separate function
    if [ ! -v newAlbumArtist ]; then
        if [ "${newArtist}" != "${originalArtist}" ]; then
            logDebug "new album artist not set when changing artist, assuming same as new artist."
            newAlbumArtist="${newArtist}"
        else
            logDebug "new album artist not set, using original album artist."
            newAlbumArtist="${originalAlbumArtist}"
        fi
    fi

    if [ -z "${newAlbum}" ]; then
        logDebug "new album is blank, blanking new album artist to match."
        newAlbumArtist=""
    fi

    if [ -z "${originalAlbum}" ] && [ -n "${newAlbum}" ] && [ -z "${newAlbumArtist}" ] ; then
        logDebug "assuming new album artist is the same as original artist when adding album information."
        newAlbumArtist="${originalArtist}"
    fi

    logDebug "newTitle = ${newTitle}, newArtist = ${newArtist}, newAlbum = ${newAlbum}, newAlbumArtist = ${newAlbumArtist}"
}

detectInvalidChange() {
    local -r original="${originalTitle}${originalArtist}${originalAlbum}${originalAlbumArtist}"
    local -r new="${newTitle}${newArtist}${newAlbum}${newAlbumArtist}"

    if [ "${original,,}" == "${new,,}" ]; then
        logError "Case-only changes cannot be applied!"
        exit 5
    fi

    if [ -z "${newTitle}" ] || [ -z "${newArtist}" ] ; then
        logError "can't erase title or artist!"
        exit 5
    fi
}

printEditData() {
    echo -e "\e[31m-${timestamp}\t${originalTitle}\t${originalArtist}\t${originalAlbum}\t${originalAlbumArtist}\e[0m"
    echo -e "\e[32m+${timestamp}\t${newTitle}\t${newArtist}\t${newAlbum}\t${newAlbumArtist}\e[0m"
}

requestConfirmation() {
    read -p "Send this edit request? (uppercase Y to confirm, anything else to abort): " -n 1 -r

    if [[ ! ${REPLY} =~ ^Y$ ]]; then
        echo
        logInfo "Aborted by user."
        exit 0
    fi

    echo
}

handleEditErrors() {
    # wrong CSRF token
    # wrong session ID
    rm -f "${verbose}" "${editResponsePath}"
}

requestScrobbleEdit() {
    detectInvalidChange

    local -r url="https://www.last.fm/user/${LASTFM_USERNAME}/library/edit?edited-variation=recent-track"
    local -r referer="Referer: https://www.last.fm/user/${LASTFM_USERNAME}"
    local -r content="Content-Type: application/x-www-form-urlencoded; charset=UTF-8"
    local -r cookies="Cookie: csrftoken=${LASTFM_CSRF}; sessionid=${LASTFM_SESSION_ID}"
    local request=""

    request+="csrfmiddlewaretoken=${LASTFM_CSRF}"
    request+="&track_name=$(urlEncode "${newTitle}")"
    request+="&artist_name=$(urlEncode "${newArtist}")"
    request+="&album_name=$(urlEncode "${newAlbum}")"
    request+="&album_artist_name=$(urlEncode "${newAlbumArtist}")"
    request+="&timestamp=${timestamp}"
    request+="&track_name_original=$(urlEncode "${originalTitle}")"
    request+="&artist_name_original=$(urlEncode "${originalArtist}")"
    request+="&album_name_original=$(urlEncode "${originalAlbum}")"
    request+="&album_artist_name_original=$(urlEncode "${originalAlbumArtist}")"
    request+="&submit=edit-scrobble"

    logInfo "This is the edit that will be applied:"
    printEditData

    logDebug "request = ${request}"
    requestConfirmation

    editResponsePath="$(mktemp -t lfmedit.html.XXXXXX)"
    logDebug "editResponsePath = ${editResponsePath}"

    curl ${silent} "${url}" \
        -H "${referer}" \
        -H "${content}" \
        -H "${cookies}" \
        --data-raw "${request}" \
        -o "${editResponsePath}"

    logDebug "edit request was sent"

    handleEditErrors
}

main() {
    parseArguments "${@}"
    checkAuthTokens
    requestOriginalScrobbleData
    extractOriginalScrobbleData
    setNewScrobbleData
    requestScrobbleEdit
}

main "${@}"
