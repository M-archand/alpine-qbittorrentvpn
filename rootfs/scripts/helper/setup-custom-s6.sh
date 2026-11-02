#!/bin/bash
# shellcheck shell=bash
# S6_STAGE2_HOOK (see Dockerfile): runs as root on every boot, right before s6-rc compiles /etc/s6-overlay/s6-rc.d.
# Merges the s6-rc components mounted at /custom-init and /custom-services into the tree as custom-<name> and adds
# them to the init / user bundle. Any problem parks the container (fail_init in functions.sh) naming the component,
# instead of leaving a half-copied component for s6-rc-compile to reject with a generic error.
# Every /custom-services component gets a dependency on the init bundle: the kill switch only exists once init-network
# has run, and a service that started earlier would send its traffic over the docker interface unprotected.

set -euo pipefail

# shellcheck disable=SC1091
source /scripts/helper/functions.sh

CUSTOM_INIT_DIR="/custom-init"
CUSTOM_SERVICES_DIR="/custom-services"
S6_RC_DIR="/etc/s6-overlay/s6-rc.d"

on_error() {
    fail_init "[custom-s6] setup-custom-s6.sh failed at line $1 (exit code $?): $2"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# Usage: process_components <source dir> <bundle> <required dependency or "">
process_components() {
    local source_dir=$1 bundle=$2 required_dependency=$3 component original_name name target type file

    if [[ ! -d "${source_dir}" ]]; then
        return 0
    fi

    for component in "${source_dir}"/*/; do
        [[ -d "${component}" ]] || continue
        component="${component%/}"
        original_name="$(basename "${component}")"
        name="custom-${original_name}"
        target="${S6_RC_DIR}/${name}"

        # What s6-rc-compile would reject anyway, checked here so the error names the component
        if [[ ! -f "${component}/type" ]]; then
            fail_init "[custom-s6] ${component} has no 'type' file (expected longrun, oneshot or bundle)"
        fi
        type="$(tr -d '[:space:]' < "${component}/type")"
        case "${type}" in
            longrun)
                [[ -f "${component}/run" ]] || fail_init "[custom-s6] ${component} is a longrun without a 'run' script"
                ;;
            oneshot)
                [[ -f "${component}/up" || -f "${component}/run" ]] || fail_init "[custom-s6] ${component} is a oneshot without an 'up' or 'run' script"
                ;;
            bundle) ;;
            *)
                fail_init "[custom-s6] ${component} has unknown type '${type}' (expected longrun, oneshot or bundle)"
                ;;
        esac

        # Fresh copy on every boot: the image layer survives 'docker restart', a stale copy would hide the user's edits
        log_info "[custom-s6] Copying ${component} to ${target}..."
        rm -rf "${target}"
        if ! cp -r "${component}" "${target}"; then
            fail_init "[custom-s6] Could not copy ${component} to ${target}"
        fi

        # Scripts must be executable whatever the mount gives us
        for file in run up down finish; do
            if [[ -f "${target}/${file}" ]]; then
                chmod +x "${target}/${file}"
            fi
        done

        # s6-rc runs a oneshot through its execline 'up' script; wrap a shell 'run' script when no 'up' is provided
        if [[ "${type}" == "oneshot" && ! -f "${target}/up" ]]; then
            log_info "[custom-s6] Creating 'up' wrapper for ${name} that runs its 'run' script..."
            printf '%s\n' "${target}/run" > "${target}/up"
            chmod +x "${target}/up"
        fi

        # Bundles cannot have dependencies, their contents get theirs when they are processed themselves
        if [[ -n "${required_dependency}" && "${type}" != "bundle" && ! -f "${target}/dependencies.d/${required_dependency}" ]]; then
            log_info "[custom-s6] ${name} now depends on ${required_dependency}: it starts once the kill switch and the tunnel are up"
            mkdir -p "${target}/dependencies.d"
            touch "${target}/dependencies.d/${required_dependency}"
        fi

        mkdir -p "${S6_RC_DIR}/${bundle}/contents.d"
        touch "${S6_RC_DIR}/${bundle}/contents.d/${name}"
        log_info "[custom-s6] ${name} added to the ${bundle} bundle"
    done
}

process_components "${CUSTOM_INIT_DIR}" "init" ""
process_components "${CUSTOM_SERVICES_DIR}" "user" "init"
