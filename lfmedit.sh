#!/bin/bash

DEBUG=${DEBUG:-0}

if [ "${DEBUG}" -ge 2 ]; then
    verbose="--verbose"
    silent=""
else
    verbose=""
    silent="--silent"
fi

logDebug() {
    if [ "${DEBUG}" -ge 1 ]; then
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

parseArguments() {
    # TODO implement parsing of command-line arguments
    logDebug "args = ${@}"
    username="${LASTFM_USERNAME}"
    timestamp="${1}"
}

checkAuthTokens() {
    if [ -z "${username}" ]; then
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

    logDebug "username = ${username}, timeFrom = ${timeFrom}, timeTo = ${timeTo}"
    curl ${silent} -o "${apiResponsePath}" "${apiRoot}?method=user.getrecenttracks&api_key=${LASTFM_API_KEY}&user=${username}&format=json&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}"
    local -r curlStatus="${?}"

    if [ ${curlStatus} -ne 0 ]; then
        logError "last.fm API request failed! curl error = ${curlStatus}"
        rm -f ${verbose} "${apiResponsePath}"
        exit 2
    fi

    if [ "${DEBUG}" -ge 2 ]; then
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
    logDebug "title = ${originalTitle}, artist = ${originalArtist}, album = ${originalAlbum}"

    rm -f ${verbose} ${apiResponsePath}
    apiResponsePath=""
}

urlEncode() {
    echo -n "${1}" | jq --slurp --raw-input --raw-output @uri
}

requestScrobbleEdit() {
    # There's no way to get original album artist from last.fm API.
    # In most cases this will be the same as track artist.
    # TODO allow setting original album artist from command line.
    if [ -z "${originalAlbumArtist}" ]; then
        logWarning "assuming original album artist is ${originalArtist}"
        local -r originalAlbumArtist="${originalArtist}"
    fi

    local -r url="https://www.last.fm/user/${username}/library/edit?edited-variation=recent-track"
    local -r referer="Referer: https://www.last.fm/user/${username}"
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

    logDebug "cookies = ${cookies}"
    logDebug "request = ${request}"
}

parseEditResponse() {
    # wrong CSRF token
    # wrong session ID
    logDebug
}

main() {
    parseArguments "${@}"
    checkAuthTokens
    requestScrobbleData
    parseApiResponse
    requestScrobbleEdit
    parseEditResponse
}

username=""
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

main "${@}"
