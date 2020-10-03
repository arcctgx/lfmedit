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
    read -p "Proceed? (uppercase Y to confirm, anything else to abort): " -n 1 -r

    if [[ ! ${REPLY} =~ ^Y$ ]]; then
        echo
        logInfo "Aborted by user."
        exit 0
    fi

    echo
}
