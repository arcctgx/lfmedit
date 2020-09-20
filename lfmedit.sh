#!/bin/bash

logDebug() {
    if [ "${debugLevel}" -ge 1 ]; then
        echo -e "\e[90mDBG: ${FUNCNAME[1]}(): ${@}\e[0m"
    fi
}

logInfo() {
    echo "INF: ${FUNCNAME[1]}(): ${@}"
}

logWarning() {
    echo -e "\e[33mWRN: ${FUNCNAME[1]}(): ${@}\e[0m"
}

logError() {
    echo -e "\e[31mERR: ${FUNCNAME[1]}(): ${@}\e[0m"
}

usage() {
    echo "usage: $(basename $0) <parameters>"
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
    if [ -z "${timestamp}" ]; then
        logError "Unix timestamp (-u) must be provided!"
        return 1
    fi

    if [ -z "${newTitle}" -a -z "${newArtist}" -a -z "${newAlbum}" -a -z "${newAlbumArtist}" ]; then
        logError "At least one of -t/-a/-b/-z parameters must be provided!"
        return 1
    fi

    return 0
}

parseArguments() {
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
        esac
    done

    if [ "${debugLevel}" -ge 2 ]; then
        verbose="--verbose"
        silent=""
    else
        verbose=""
        silent="--silent"
    fi

    logDebug "args = ${@}"

    if ! checkMandatoryParameters; then
        logError "Missing mandatory parameters!"
        echo
        usage
    fi
}

checkAuthTokens() {
    if [ -z "${LASTFM_USERNAME}" ]; then
        logError "last.fm username not provided, exiting!"
        exit 1
    elif [ -z ${LASTFM_API_KEY} ]; then
        logError "last.fm API key is not provided, exiting!"
        exit 1
    elif [ -z "${LASTFM_CSRF}" ]; then
        logError "last.fm CSRF token is not provided, exiting!"
        exit 1
    elif [ -z "${LASTFM_SESSION_ID}" ]; then
        logError "last.fm session ID is not provided, exiting!"
        exit 1
    fi

    logInfo "all necessary authentication tokens are set"
}

requestScrobbleData() {
    apiResponsePath="$(mktemp -t lfmquery.json.XXXXXX)"
    logDebug "apiResponsePath = ${apiResponsePath}"

    local -r apiRoot="http://ws.audioscrobbler.com/2.0/"
    local -r timeFrom="${timestamp}"
    local -r timeTo=$((timeFrom+1))     # a hack to limit results to a single scrobble
    local -r perPage=1                  # request one scrobble per page...
    local -r page=1                     # ...and only the first page of results.

    logDebug "username = ${LASTFM_USERNAME}, timeFrom = ${timeFrom}, timeTo = ${timeTo}"
    curl ${silent} -o "${apiResponsePath}" "${apiRoot}?method=user.getrecenttracks&api_key=${LASTFM_API_KEY}&user=${LASTFM_USERNAME}&format=json&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}"
    local -r curlStatus="${?}"

    if [ ${curlStatus} -ne 0 ]; then
        logError "last.fm API request failed! curl error = ${curlStatus}"
        rm -f ${verbose} "${apiResponsePath}"
        exit 2
    fi

    if [ "${debugLevel}" -ge 2 ]; then
        jq --monochrome-output . "${apiResponsePath}"
    fi
}

handleApiErrors() {
    # TODO actually parse response in search of API errors
    logDebug "last.fm API call was successful"
}

parseApiResponse() {
    handleApiErrors

    # We expect that there are at most two tracks in the response:
    # "now playing" (optional), and the one we want (always last).
    # The attribute "total" holds the number of returned scrobbles,
    # excluding "now playing" one. This should be equal to one.
    local -r total=$(jq -r '.recenttracks."@attr".total' "${apiResponsePath}")
    logDebug "total = ${total}"
    if [ "${total}" -ne 1 ]; then
        logError "unexpected number of scrobbles in API response! (got ${total} instead of 1)"
        rm -f ${verbose} "${apiResponsePath}"
        exit 4
    fi

    # Compare timestamps to make sure we got the scrobble we wanted.
    local -r uts=$(jq -r '.recenttracks.track[-1].date.uts' "${apiResponsePath}")
    if [ "${uts}" -eq "${timestamp}" ]; then
        logDebug "got scrobble with matching timestamp: uts = $uts"
    else
        logError "scrobble timestamp mismatch! (expected: ${timestamp}, received: ${uts})"
        rm -f ${verbose} "${apiResponsePath}"
        exit 4
    fi

    originalTitle=$(jq -r '.recenttracks.track[-1].name' "${apiResponsePath}")
    originalArtist=$(jq -r '.recenttracks.track[-1].artist["#text"]' "${apiResponsePath}")
    originalAlbum=$(jq -r '.recenttracks.track[-1].album["#text"]' "${apiResponsePath}")
    logDebug "originalTitle = ${originalTitle}, originalArtist = ${originalArtist}, originalAlbum = ${originalAlbum}"

    # There's no way to get original album artist from last.fm API.
    # In most cases this will be the same as track artist.
    if [ -z "${originalAlbumArtist}" ]; then
        logWarning "assuming original album artist is the same as original track artist (use -Z to override)"
        originalAlbumArtist="${originalArtist}"
    fi
    logDebug "originalAlbumArtist = ${originalAlbumArtist}"

    rm -f ${verbose} ${apiResponsePath}
    apiResponsePath=""
}

urlEncode() {
    echo -n "${1}" | jq --slurp --raw-input --raw-output @uri
}

setNewScrobbleData() {
    if [ -z "${newTitle}" ]; then
        newTitle="${originalTitle}"
    fi

    if [ -z "${newArtist}" ]; then
        newArtist="${originalArtist}"
    fi

    if [ -z "${newAlbum}" ]; then
        newAlbum="${originalAlbum}"
    fi

    if [ -z "${newAlbumArtist}" ]; then
        newAlbumArtist="${originalAlbumArtist}"
    fi

    logDebug "newTitle = ${newTitle}, newArtist = ${newArtist}, newAlbum = ${newAlbum}, newAlbumArtist = ${newAlbumArtist}"
}

detectCaseOnlyChange() {
    local -r original="${originalTitle}${originalArtist}${originalAlbum}${originalAlbumArtist}"
    local -r new="${newTitle}${newArtist}${newAlbum}${newAlbumArtist}"

    if [ "${original,,}" == "${new,,}" ]; then
        logError "Case-only changes cannot be applied!"
        exit 5
    fi
}

printEditData() {
    echo -e "\e[31m-${timestamp}\t${originalTitle}\t${originalArtist}\t${originalAlbum}\t${originalAlbumArtist}\e[0m"
    echo -e "\e[32m+${timestamp}\t${newTitle}\t${newArtist}\t${newAlbum}\t${newAlbumArtist}\e[0m"
}

requestScrobbleEdit() {
    setNewScrobbleData
    detectCaseOnlyChange

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
}

parseEditResponse() {
    # wrong CSRF token
    # wrong session ID
    logDebug
}

main() {
    debugLevel=0
    silent=""
    verbose=""
    timestamp=""
    originalTitle=""
    originalArtist=""
    originalAlbum=""
    originalAlbumArtist=""
    newTitle=""
    newArtist=""
    newAlbum=""
    newAlbumArtist=""
    apiResponsePath=""

    parseArguments "${@}"
    checkAuthTokens
    requestScrobbleData
    parseApiResponse
    requestScrobbleEdit
    parseEditResponse
}

main "${@}"
