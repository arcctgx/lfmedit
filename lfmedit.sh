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

unquote() {
    echo "${1}" | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g'
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
    curl ${silent} --output "${apiResponsePath}" "${apiRoot}?method=user.getrecenttracks&api_key=${LASTFM_API_KEY}&user=${username}&format=json&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}"
    local -r curlStatus="${?}"

    if [ ${curlStatus} -ne 0 ]; then
        logError "last.fm API request failed! curl error = ${curlStatus}"
        rm --force ${verbose} "${apiResponsePath}"
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

    # We're requesting one page of output with one scrobble per page.
    # There could be one or two scrobbles in query result (two in case
    # last.fm also returns "now playing" track).
    local -r numTracks=$(jq ".recenttracks.track | length" "${apiResponsePath}")
    if [ "${numTracks}" -ne 1 -a "${numTracks}" -ne 2 ]; then
        logError "unexpected numTracks = ${numTracks}, exiting!"
        rm --force ${verbose} "${apiResponsePath}"
        exit
    fi

    # If two tracks are returned, the first one is "now playing" - ignore it.
    local -r index=$((numTracks-1))
    logDebug "numTracks = ${numTracks}, index = ${index}"

    oldTitle=$(unquote "$(jq ".recenttracks.track[${index}].name" "${apiResponsePath}")")
    oldArtist=$(unquote "$(jq ".recenttracks.track[${index}].artist[\"#text\"]" "${apiResponsePath}")")
    oldAlbum=$(unquote "$(jq ".recenttracks.track[${index}].album[\"#text\"]" "${apiResponsePath}")")
    logDebug "title = ${oldTitle}, artist = ${oldArtist}, album = ${oldAlbum}"

    rm --force ${verbose} ${apiResponsePath}
    apiResponsePath=""
}

urlEncode() {
    echo -n "${1}" | jq --slurp --raw-input --raw-output @uri
}

main() {
    parseArguments "${@}"
    checkAuthTokens
    requestScrobbleData
    parseApiResponse
}

username=""
timestamp=""
oldTitle=""
oldArtist=""
oldAlbum=""
oldAlbumArtist=""
apiResponsePath=""

main "${@}"
