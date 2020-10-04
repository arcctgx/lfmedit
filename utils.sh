#!/bin/bash

debugLevel=0

logDebug() {
    if [ "${debugLevel}" -ge 1 ]; then
        echo -e "\e[90mDBG: ${FUNCNAME[1]}(): ${*}\e[0m"
    fi
}

logInfo() {
    echo -e "INF: ${FUNCNAME[1]}(): ${*}"
}

logWarning() {
    echo -e "\e[33mWRN: ${FUNCNAME[1]}(): ${*}\e[0m"
}

logError() {
    echo -e "\e[31mERR: ${FUNCNAME[1]}(): ${*}\e[0m"
}

checkAuthTokens() {
    if [ -f auth_tokens.sh ]; then
        logDebug "reading auth_tokens.sh file"
        source auth_tokens.sh
    fi

    if [ -z "${lastfm_username}" ]; then
        logError "last.fm username not provided, exiting!"
        return 1
    elif [ -z "${lastfm_session_id}" ]; then
        logError "last.fm session ID is not provided, exiting!"
        return 2
    elif [ -z "${lastfm_csrf}" ]; then
        logError "last.fm CSRF token is not provided, exiting!"
        return 3
    fi

    logDebug "all necessary authentication tokens are set"
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

requestConfirmation() {
    read -u 1 -p "Proceed? (uppercase Y to confirm, anything else to abort): " -n 1 -r

    if [[ ! ${REPLY} =~ ^Y$ ]]; then
        echo
        logInfo "Not applying this edit."
        return 1
    fi

    echo
}
