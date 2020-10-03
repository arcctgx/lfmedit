#!/bin/bash

source "utils.sh"

# Requires following global variables to be set:
# timestamp, silent, verbose

handleApiErrors() {
    if [[ ${debugLevel} -ge 2 ]]; then
        jq --monochrome-output . "${apiResponsePath}"
    fi

    if [[ $(jq 'has("error")' "${apiResponsePath}") == "true" ]]; then
        local -r errcode=$(jq '.error' "${apiResponsePath}")
        local -r message=$(jq -r '.message' "${apiResponsePath}")
        logError "error ${errcode}: ${message}"
        rm -f "${verbose}" "${apiResponsePath}"
        exit 3
    fi
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

    logDebug "username = ${lastfm_username}, timeFrom = ${timeFrom}, timeTo = ${timeTo}"

    url+="${apiRoot}?method=user.getrecenttracks&api_key=${apiKey}"
    url+="&user=${lastfm_username}"
    url+="&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}&format=json"

    local -r httpCode=$(curl ${silent} -o "${apiResponsePath}" -w "%{http_code}\n" "${url}")
    local -r curlStatus="${?}"

    if [[ ${curlStatus} -ne 0 ]]; then
        logError "failed to send last.fm API request! curl error = ${curlStatus}"
        rm -f "${verbose}" "${apiResponsePath}"
        exit 2
    fi

    logDebug "API request was sent"

    if [[ ${httpCode} -ne 200 ]]; then
        logError "received HTTP error ${httpCode} while sending API request!"
        rm -f "${verbose}" "${apiResponsePath}"
        exit 2
    fi

    handleApiErrors
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

requestScrobbleEdit() {
    detectInvalidChange

    local -r url="https://www.last.fm/user/${lastfm_username}/library/edit?edited-variation=recent-track"
    local -r referer="Referer: https://www.last.fm/user/${lastfm_username}"
    local -r content="Content-Type: application/x-www-form-urlencoded; charset=UTF-8"
    local -r cookies="Cookie: csrftoken=${lastfm_csrf}; sessionid=${lastfm_session_id}"
    local request=""

    request+="csrfmiddlewaretoken=${lastfm_csrf}"
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

    local -r httpCode=$(curl ${silent} -o /dev/null -w "%{http_code}\n" "${url}" \
        -H "${referer}" \
        -H "${content}" \
        -H "${cookies}" \
        --data-raw "${request}")
    local -r curlStatus="${?}"

    if [[ ${curlStatus} -ne 0 ]]; then
        logError "failed to send last.fm edit request! curl error = ${curlStatus}"
        exit 6
    fi

    logDebug "edit request was sent"

    if [[ ${httpCode} -ne 200 ]]; then
        case "${httpCode}" in
            403)
                logError "HTTP error ${httpCode}: check last.fm CSRF token"
                ;;
            404)
                logError "HTTP error ${httpCode}: check last.fm session ID"
                ;;
            500)
                logError "HTTP error ${httpCode}: check edit parameters (wrong original album artist?)"
                ;;
            *)
                logError "HTTP error ${httpCode}"
                ;;
        esac

        exit 6
    fi
}

verifyScrobbleEdit() {
    # Method: send a "pre-edit" POST request with parameters containing new
    # scrobble data (expected to be set on last.fm side after successful edit).
    # In case of unsuccessful edit last.fm will still have original data, and the
    # request will fail with HTTP error 500. Otherwise the request will be successful,
    # and it will contain new scrobble data in its body. For now I'm assuming I can
    # rely on the HTTP status codes, and don't parse the response.

    local -r url="https://www.last.fm/user/${lastfm_username}/library/edit?edited-variation=recent-track"
    local -r referer="Referer: https://www.last.fm/user/${lastfm_username}"
    local -r content="Content-Type: application/x-www-form-urlencoded; charset=UTF-8"
    local -r cookies="Cookie: csrftoken=${lastfm_csrf}; sessionid=${lastfm_session_id}"
    local request=""

    request+="csrfmiddlewaretoken=${lastfm_csrf}"
    request+="&artist_name=$(urlEncode "${newArtist}")"
    request+="&track_name=$(urlEncode "${newTitle}")"
    request+="&album_name=$(urlEncode "${newAlbum}")"
    request+="&album_artist_name=$(urlEncode "${newAlbumArtist}")"
    request+="&timestamp=${timestamp}"

    logDebug "request = ${request}"

    local -r httpCode=$(curl ${silent} -o /dev/null -w "%{http_code}\n" "${url}" \
        -H "${referer}" \
        -H "${content}" \
        -H "${cookies}" \
        --data-raw "${request}")
    local -r curlStatus="${?}"

    if [[ ${curlStatus} -ne 0 ]]; then
        logError "failed to send last.fm verification request! curl error = ${curlStatus}"
        exit 7
    fi

    logDebug "verification request was sent"

    case "${httpCode}" in
        200)
            logInfo "\e[1m\e[32mverification passed!\e[0m Scrobble edited successfully"
            ;;
        500)
            logError "HTTP error ${httpCode}: last.fm still has old scrobble data, edit failed!"
            exit 7
            ;;
        *)
            logError "HTTP error ${httpCode}: something else went wrong, not sure about edit status"
            exit 7
            ;;
    esac
}