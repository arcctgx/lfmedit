#!/bin/bash

source "utils.sh"

# Requires following global variables to be set:
# timestamp, silent, verbose

userAgent="lfmedit/1.0.8-a1 +https://github.com/arcctgx/lfmedit"

handleApiErrors() {
    local -r httpCode="${1}"

    if [[ ${httpCode} -ne 200 ]]; then
        logError "got HTTP error ${httpCode} while sending last.fm API request!"
    fi

    if ! jq -e . "${apiResponsePath}" &> /dev/null; then
        logError "last.fm API response is not valid JSON!"
        rm -f "${verbose}" "${apiResponsePath}"
        return 1
    fi

    if [[ ${debugLevel} -ge 2 ]]; then
        jq --monochrome-output . "${apiResponsePath}"
    fi

    if [[ "$(jq 'has("error")' "${apiResponsePath}")" == "true" ]]; then
        local -r errcode=$(jq '.error' "${apiResponsePath}")
        local -r message=$(jq -r '.message' "${apiResponsePath}")
        logError "last.fm error ${errcode}: ${message}"
        rm -f "${verbose}" "${apiResponsePath}"
        return 2
    fi
}

requestOriginalScrobbleData() {
    # I'm not sure if scrobbles submitted before Feb 13 2005, 10:20:00 UTC
    # (1108290000 Unix time) can be handled by this method.
    # Adding 100 seconds to the limit because the scrobbles without reliable
    # timestamp information reach 1108290047 in my exported data.
    local -r earliest=1108290100
    if [[ ${timestamp} -le ${earliest} ]]; then
        logError "Editing scrobbles before Unix time ${earliest} is not supported!"
        return 1
    fi

    apiResponsePath="$(mktemp -t lfmquery.json.XXXXXX)"
    logDebug "apiResponsePath = ${apiResponsePath}"

    local -r apiRoot="http://ws.audioscrobbler.com/2.0/"
    local -r apiKey="29a5d6e1ddfce0e472ce9a328ac21ff5"
    local -r timeFrom="${timestamp}"
    local -r timeTo=$((timeFrom+1))     # a hack to limit results to a single scrobble
    local -r perPage=1                  # request one scrobble per page...
    local -r page=1                     # ...and only the first page of results.
    local httpCode=""
    local curlStatus=""
    local url=""

    logDebug "username = ${lastfm_username}, timeFrom = ${timeFrom}, timeTo = ${timeTo}"

    url+="${apiRoot}?method=user.getrecenttracks&api_key=${apiKey}"
    url+="&user=${lastfm_username}"
    url+="&from=${timeFrom}&to=${timeTo}&limit=${perPage}&page=${page}&format=json"

    # shellcheck disable=SC2086
    httpCode=$(curl ${silent} -o "${apiResponsePath}" -w "%{http_code}\n" "${url}" \
        --user-agent "${userAgent}")
    curlStatus=${?}

    if [[ ${curlStatus} -ne 0 ]]; then
        logError "failed to send last.fm API request! curl error = ${curlStatus}"
        rm -f "${verbose}" "${apiResponsePath}"
        return 2
    fi

    logDebug "last.fm API request was sent, httpCode = ${httpCode}"

    handleApiErrors "${httpCode}" || return 3
}

readOriginalScrobbleData() {
    # We expect that there are at most two tracks in the response:
    # "now playing" (optional), and the one we want (always last).
    # The attribute "total" holds the number of returned scrobbles,
    # excluding "now playing" one. This should be equal to one.
    local -r total=$(jq -r '.recenttracks."@attr".total' "${apiResponsePath}")
    logDebug "total = ${total}"
    if [[ ${total} -ne 1 ]]; then
        logError "unexpected number of scrobbles in API response! (got ${total} instead of 1)"
        rm -f "${verbose}" "${apiResponsePath}"
        return 1
    fi

    # Compare timestamps to make sure we got the scrobble we wanted.
    local -r uts=$(jq -r '.recenttracks.track[-1].date.uts' "${apiResponsePath}")
    if [[ ${uts} -eq ${timestamp} ]]; then
        logDebug "got scrobble with matching timestamp: uts = $uts"
    else
        logError "scrobble timestamp mismatch! (expected: ${timestamp}, received: ${uts})"
        rm -f "${verbose}" "${apiResponsePath}"
        return 2
    fi

    originalTitle=$(jq -r '.recenttracks.track[-1].name' "${apiResponsePath}")
    originalArtist=$(jq -r '.recenttracks.track[-1].artist["#text"]' "${apiResponsePath}")
    originalAlbum=$(jq -r '.recenttracks.track[-1].album["#text"]' "${apiResponsePath}")
    logDebug "originalTitle = ${originalTitle}, originalArtist = ${originalArtist}, originalAlbum = ${originalAlbum}"

    # There's no way to get original album artist from last.fm API.
    # If it was not provided by -Z option, we have to guess.
    # In most cases this will be the same as track artist.
    if [[ ! -v originalAlbumArtist ]]; then
        logDebug "assuming original album artist is the same as original track artist"
        originalAlbumArtist="${originalArtist}"
    fi

    # If there's no original album, then original album artist must be blank too.
    if [[ -z "${originalAlbum}" ]]; then
        logDebug "no original album set for scrobble, assuming empty original album artist."
        originalAlbumArtist=""
    fi

    logDebug "originalAlbumArtist = ${originalAlbumArtist}"

    rm -f "${verbose}" "${apiResponsePath}"
}

setNewAlbumArtist() {
    if [[ ! -v newAlbumArtist ]]; then
        if [[ "${newArtist}" != "${originalArtist}" ]]; then
            logDebug "new album artist not set when changing artist, assuming same as new artist."
            newAlbumArtist="${newArtist}"
        else
            logDebug "new album artist not set, using original album artist."
            newAlbumArtist="${originalAlbumArtist}"
        fi
    fi

    if [[ -z "${newAlbum}" ]]; then
        logDebug "new album is blank, blanking new album artist to match."
        newAlbumArtist=""
    fi

    if [[ -z "${originalAlbum}" && -n "${newAlbum}" && -z "${newAlbumArtist}" ]]; then
        logDebug "assuming new album artist is the same as original artist when adding album information."
        newAlbumArtist="${originalArtist}"
    fi
}

setNewScrobbleData() {
    if [[ ! -v newTitle ]]; then
        newTitle="${originalTitle}"
    fi

    if [[ ! -v newArtist ]]; then
        newArtist="${originalArtist}"
    fi

    if [[ ! -v newAlbum ]]; then
        newAlbum="${originalAlbum}"
    fi

    setNewAlbumArtist

    logDebug "newTitle = ${newTitle}, newArtist = ${newArtist}, newAlbum = ${newAlbum}, newAlbumArtist = ${newAlbumArtist}"
}

detectInvalidChange() {
    if [[ "${originalTitle}" == "${newTitle}" && \
          "${originalArtist}" == "${newArtist}" && \
          "${originalAlbum}" == "${newAlbum}" && \
          "${originalAlbumArtist}" == "${newAlbumArtist}" ]]; then
        logError "Edit does not change anything!"
        return 1
    fi

    if [[ "${originalTitle,,}" == "${newTitle,,}" && \
          "${originalArtist,,}" == "${newArtist,,}" && \
          "${originalAlbum,,}" == "${newAlbum,,}" && \
          "${originalAlbumArtist,,}" == "${newAlbumArtist,,}" ]]; then
        logError "Case-only changes cannot be applied!"
        return 2
    fi

    if [[ -z "${newTitle}" || -z "${newArtist}" ]]; then
        logError "Can't erase title or artist!"
        return 3
    fi
}

printEditData() {
    echo -e "\e[94m-${timestamp}    ${originalTitle}    ${originalArtist}    ${originalAlbum}    ${originalAlbumArtist}\e[0m"
    echo -e "\e[92m+${timestamp}    ${newTitle}    ${newArtist}    ${newAlbum}    ${newAlbumArtist}\e[0m"
}

getCsrfMiddlewareToken() {
    # Do an authenticated GET request to fetch any user page that contains
    # a form. Extract the csfmiddlewaretoken from a hidden form field and
    # set it globally in the script. The token is not ephemeral (I think it
    # is valid as long as the csrftoken cookie is valid), so we can fetch
    # it once and reuse it as many times as needed.

    if [[ -n "${csrfmiddlewaretoken}" ]]; then
        logDebug "CSRF middleware token is already set"
        return 0
    fi

    logDebug "need to fetch CSRF middleware token"

    local -r url="https://www.last.fm/user/${lastfm_username}/library"
    local httpCode=""
    local curlStatus=""

    local -r tokenResponsePath="$(mktemp -t lfmedit-csrf.html.XXXXXX)"
    logDebug "tokenResponsePath = ${tokenResponsePath}"

    # shellcheck disable=SC2086
    httpCode="$(curl ${silent} -w "%{http_code}\n" -o "${tokenResponsePath}" "${url}" \
        --compressed \
        --user-agent "${userAgent}" \
        --cookie "csrftoken=${lastfm_csrf}; sessionid=${lastfm_session_id}")"
    curlStatus="${?}"

    if [[ "${curlStatus}" -ne 0 ]]; then
        logError "failed to send request for CSRF middleware token! curl error = ${curlStatus}"
        rm -f "${verbose}" "${tokenResponsePath}"
        return 1
    fi

    logDebug "request for CSRF middleware token was sent, httpCode = ${httpCode}"

    if [[ "${httpCode}" -ne 200 ]]; then
        logError "HTTP error ${httpCode} when getting CSRF middleware token!"
        rm -f "${verbose}" "${tokenResponsePath}"
        return 2
    fi

    csrfmiddlewaretoken=$(grep -m1 "input.*hidden.*csrfmiddlewaretoken.*value=" "${tokenResponsePath}" |
        grep -o -E "[A-Za-z0-9]{64}")
    # alternative: grep -m1 csrfmiddlewaretoken "${tokenResponsePath}" | cut -d\' -f6
    rm -f "${verbose}" "${tokenResponsePath}"

    if [[ ! -n "${csrfmiddlewaretoken}" ]]; then
        logError "Failed to find CSRF middleware token in the response body!"
        return 3
    fi

    logDebug "CSRF middleware token = ${csrfmiddlewaretoken}"
}

requestScrobbleEdit() {
    setNewScrobbleData

    logInfo "This is the edit that will be applied:"
    printEditData

    detectInvalidChange || return 1

    local -r url="https://www.last.fm/user/${lastfm_username}/library/edit?edited-variation=recent-track"
    local -r referer="https://www.last.fm/user/${lastfm_username}"
    local -r cookies="csrftoken=${lastfm_csrf}; sessionid=${lastfm_session_id}"
    local httpCode=""
    local curlStatus=""

    requestConfirmation || return 2
    getCsrfMiddlewareToken || return 10

    # shellcheck disable=SC2086
    httpCode=$(curl ${silent} -o /dev/null -w "%{http_code}\n" "${url}" \
        --user-agent "${userAgent}" \
        --referer "${referer}" \
        --cookie "${cookies}" \
        --data-urlencode "csrfmiddlewaretoken=${csrfmiddlewaretoken}" \
        --data-urlencode "track_name=${newTitle}" \
        --data-urlencode "artist_name=${newArtist}" \
        --data-urlencode "album_name=${newAlbum}" \
        --data-urlencode "album_artist_name=${newAlbumArtist}" \
        --data-urlencode "timestamp=${timestamp}" \
        --data-urlencode "track_name_original=${originalTitle}" \
        --data-urlencode "artist_name_original=${originalArtist}" \
        --data-urlencode "album_name_original=${originalAlbum}" \
        --data-urlencode "album_artist_name_original=${originalAlbumArtist}" \
        --data-urlencode "submit=edit-scrobble" \
        --data-urlencode "ajax=1")
    curlStatus="${?}"

    if [[ ${curlStatus} -ne 0 ]]; then
        logError "failed to send last.fm edit request! curl error = ${curlStatus}"
        return 3
    fi

    logDebug "last.fm edit request was sent, httpCode = ${httpCode}"

    if [[ ${httpCode} -ne 200 ]]; then
        case "${httpCode}" in
            403)
                logError "HTTP error ${httpCode}: check last.fm CSRF token"
                ;;
            404)
                logError "HTTP error ${httpCode}: check last.fm session ID"
                ;;
            406)
                logError "HTTP error ${httpCode}: throttling detected, try again later"
                ;;
            500)
                logError "HTTP error ${httpCode}: check edit parameters (wrong original album artist?)"
                ;;
            *)
                logError "HTTP error ${httpCode}"
                ;;
        esac

        return 4
    fi
}

verifyScrobbleEdit() {
    # Method: send a "pre-edit" POST request with parameters containing new
    # scrobble data (expected to be set on last.fm side after successful edit).
    # In case of unsuccessful edit last.fm will still have original data, and the
    # request will fail with HTTP error 500. Otherwise the request will be successful,
    # and it will contain new scrobble data in its body. For now I'm assuming I can
    # rely on the HTTP status codes, and don't parse the response.

    # It turns out false positives are possible, so don't enable verification by default.
    if [[ ! -v enableVerification || "${enableVerification}" != "yes" ]]; then
        return 0
    fi

    local -r url="https://www.last.fm/user/${lastfm_username}/library/edit?edited-variation=recent-track"
    local -r referer="https://www.last.fm/user/${lastfm_username}"
    local -r cookies="csrftoken=${lastfm_csrf}; sessionid=${lastfm_session_id}"
    local httpCode=""
    local curlStatus=""

    getCsrfMiddlewareToken || return 10

    # shellcheck disable=SC2086
    httpCode=$(curl ${silent} -o /dev/null -w "%{http_code}\n" "${url}" \
        --user-agent "${userAgent}" \
        --referer "${referer}" \
        --cookie "${cookies}" \
        --data-urlencode "csrfmiddlewaretoken=${csrfmiddlewaretoken}" \
        --data-urlencode "artist_name=${newArtist}" \
        --data-urlencode "track_name=${newTitle}" \
        --data-urlencode "album_name=${newAlbum}" \
        --data-urlencode "album_artist_name=${newAlbumArtist}" \
        --data-urlencode "timestamp=${timestamp}" \
        --data-urlencode "ajax=1")
    curlStatus="${?}"

    if [[ ${curlStatus} -ne 0 ]]; then
        logError "failed to send last.fm verification request! curl error = ${curlStatus}"
        return 1
    fi

    logDebug "last.fm verification request was sent, httpCode = ${httpCode}"

    case "${httpCode}" in
        200)
            logInfo "\e[1m\e[32mverification passed!\e[0m Scrobble edited successfully"
            ;;
        500)
            logError "HTTP error ${httpCode}: last.fm still has old scrobble data, edit failed!"
            return 2
            ;;
        *)
            logError "HTTP error ${httpCode}: something else went wrong, not sure about edit status"
            return 3
            ;;
    esac
}
