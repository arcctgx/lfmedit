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
        echo -e "\e[90mDBG: ${1}\e[0m"
    fi
}

logInfo() {
    echo "INF: ${1}"
}

logError() {
    echo -e "\e[31mERR: ${1}\e[0m"
}

checkAuthTokens() {
    if [ -z ${LASTFM_API_KEY} ]; then
        logError "last.fm API key is not provided, exiting!"
        exit 1
    elif [ -z "${LASTFM_USERNAME}" ]; then
        logError "last.fm username not provided, exiting!"
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

getCurrentScrobbleData() {
    local -r apiRoot="http://ws.audioscrobbler.com/2.0/"
    local -r tmpfile="$(mktemp -t lfmquery.json.XXXXXX)"
    local -r timeFrom="${1}"
    local -r timeTo=$((timeFrom+1))     # a hack to limit results to a single scrobble
    local -r perPage=1                  # request one scrobble per page...
    local -r page=1                     # ...and only the first page of results.

    logDebug "timeFrom = ${timeFrom}, timeTo = ${timeTo}, tmpfile = ${tmpfile}"
    curl ${silent} --output "${tmpfile}" "${apiRoot}?method=user.getrecenttracks&api_key=${LASTFM_API_KEY}&user=${LASTFM_USERNAME}&format=json&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}"

    if [ "${DEBUG}" -ge 2 ]; then
        jq --monochrome-output . "${tmpfile}"
    fi

    # TODO: handle API errors

    # We're requesting one page of output with one scrobble per page.
    # There could be one or two scrobbles in query result (two in case
    # last.fm also returns "now playing" track).
    local -r numTracks=$(jq ".recenttracks.track | length" "${tmpfile}")
    if [ "${numTracks}" -ne 1 -a "${numTracks}" -ne 2 ]; then
        logError "unexpected numTracks = ${numTracks}, exiting!"
        rm --force ${verbose} "${tmpfile}"
        exit
    fi

    # If two tracks are returned, the first one is "now playing" - ignore it.
    local -r index=$((numTracks-1))
    logDebug "numTracks = ${numTracks}, index = ${index}"

    local -r title=$(unquote "$(jq ".recenttracks.track[${index}].name" "${tmpfile}")")
    local -r artist=$(unquote "$(jq ".recenttracks.track[${index}].artist[\"#text\"]" "${tmpfile}")")
    local -r album=$(unquote "$(jq ".recenttracks.track[${index}].album[\"#text\"]" "${tmpfile}")")
    logDebug "title = ${title}, artist = ${artist}, album = ${album}"

    rm --force ${verbose} ${tmpfile}
}

urlEncode() {
    echo -n "${1}" | jq --slurp --raw-input --raw-output @uri
}

main() {
    checkAuthTokens
    getCurrentScrobbleData "${1}"
}

main "${@}"
