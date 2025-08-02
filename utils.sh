#!/bin/bash

debugLevel=0

logDebug() {
    if [[ ${debugLevel} -ge 1 ]]; then
        echo -e "\e[90mDBG: ${FUNCNAME[1]}(): ${*}\e[0m"
    fi
}

logInfo() {
    echo -e "INF: ${FUNCNAME[1]}(): ${*}"
}

logError() {
    echo -e "\e[1;31mERR: ${FUNCNAME[1]}(): ${*}\e[0m"
}

checkAuthTokens() {
    local -r config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}"
    local -r auth_tokens_file="${config_dir}/lfmedit/auth_tokens"

    if [[ -r "${auth_tokens_file}" ]]; then
        logDebug "reading authentication tokens from ${auth_tokens_file}"
        # shellcheck disable=SC1090
        source "${auth_tokens_file}"
    else
        logDebug "failed to read ${auth_tokens_file}"
    fi

    if [[ -z "${lastfm_username}" ]]; then
        logError "last.fm username not provided, exiting!"
        return 1
    elif [[ -z "${lastfm_session_id}" ]]; then
        logError "last.fm session ID is not provided, exiting!"
        return 2
    elif [[ -z "${lastfm_csrf}" ]]; then
        logError "last.fm CSRF token is not provided, exiting!"
        return 3
    fi

    logDebug "all necessary authentication tokens are set"
}

requestConfirmation() {
    if [[ -v dryRun && "${dryRun}" == "yes" ]]; then
        logInfo "Dry run: changes are not applied."
        return 2
    fi

    if [[ ! -v dontAsk || "${dontAsk}" != "yes" ]]; then
        read -u 1 -p "Proceed? (uppercase Y to confirm, anything else to abort): " -n 1 -r

        if [[ ! ${REPLY} =~ ^Y$ ]]; then
            echo
            logInfo "Not applying this edit."
            return 1
        fi

        echo
    fi
}
