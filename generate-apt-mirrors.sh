#!/usr/bin/env bash

set -e -u

DEPENDENCIES="lsb_release sudo wget"
MISSING_DEPENDENCIES=""

for DEPENDENCY in ${DEPENDENCIES}; do
    if [ "$(which "${DEPENDENCY}")" = "" ]; then
        MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES} ${DEPENDENCY}"
    fi
done

if [ "${MISSING_DEPENDENCIES}" != "" ]; then
    cat <<ERRMSG
ERROR: Missing required dependencies.

generate-apt-mirrors requires:
ERRMSG

    # shellcheck disable=SC2086
    echo ${MISSING_DEPENDENCIES} | xargs -d' ' -I % echo "- %"

    echo -n "Attempting to install missing dependencies... "

    # shellcheck disable=SC2034
    DEBIAN_FRONTEND=noninteractive

    # shellcheck disable=SC2086
    apt update -qqq && apt install -y -qqq ${MISSING_DEPENDENCIES/lsb_release/lsb-release} >/dev/null 2>&1

    if [ "$(which sudo)" = "" ] || [ "$(which wget)" = "" ]; then
        echo "FAILED!"
        exit 1
    fi

    echo "OK"
fi

MIRROR_CONF_FILES=${MIRROR_CONF_FILES:-"/etc/default/generate-apt-mirrors ./generate-apt-mirrors.conf"}

# shellcheck disable=SC2153
if [ "${MIRROR_CONF_FILE-}" != "" ]; then
    if [ ! -f "${MIRROR_CONF_FILE}" ]; then
        echo "ERROR: MIRROR_CONF_FILES was specified but could open file: ${MIRROR_CONF_FILES}"
        exit 255
    else
        # shellcheck source=/dev/null
        MIRROR_CONF_FILES="$(realpath "${MIRROR_CONF_FILE}")"
    fi
fi

for CONF_FILE in ${MIRROR_CONF_FILES-}; do
    if [ -f "${CONF_FILE}" ]; then
        # shellcheck source=/dev/null
        . "${CONF_FILE}"
    fi
done

MIRROR_SERVER=${MIRROR_SERVER:-mirrors.ubuntu.com}

MIRROR_GEOS=${MIRROR_GEOS:-CA}

if [ "${MIRROR_URIS-}" = "" ]; then
    for MIRROR_SERVER_GEO in ${MIRROR_GEOS}; do

        MIRROR_URIS="${MIRROR_URIS-} ${MIRROR_SERVER}/${MIRROR_SERVER_GEO}.txt"
    done
fi

MIRROR_DIST=${MIRROR_DIST:-$(lsb_release -cs)}

MIRROR_CHANNELS=${MIRROR_CHANNELS:-"${MIRROR_DIST} ${MIRROR_DIST}-updates"}

if [ "${MIRROR_BACKPORTS}" = "YES" ]; then
    MIRROR_CHANNELS="${MIRROR_CHANNELS} ${MIRROR_DIST}-backports"
fi

if [ "${MIRROR_SECURITY}" = "YES" ]; then
    MIRROR_CHANNELS="${MIRROR_CHANNELS} ${MIRROR_DIST}-security"
fi

MIRROR_REPOS=${MIRROR_REPOS:-"main restricted"}

if [ "${MIRROR_UNIVERSE}" = "YES" ]; then
    MIRROR_REPOS="${MIRROR_REPOS} universe"
fi

if [ "${MIRROR_UNIVERSE}" = "YES" ]; then
    MIRROR_REPOS="${MIRROR_REPOS} multiverse"
fi

MIRROR_VERBOSE_OUTPUT=${MIRROR_VERBOSE_OUTPUT:-/dev/stdout}

MIRROR_LIST_FILE=${MIRROR_LIST_FILE:-/etc/apt/sources.list.d/mirrors.list}

MIRROR_MAX_MIRRORS=${MIRROR_MAX_MIRRORS:-7}

NETSELECT_VERSION=${NETSELECT_VERSION:-"0.3.ds1-29"}

echo -n "Checking netselect installation status... "
if dpkg --list | grep -iw netselect | grep -E '^ii' >/dev/null 2>&1; then
    echo "OK"
else
    echo "MISSING"

    echo "Attempting to install netselect... "

    NETSELECT_URI=${NETSELECT_URI:-"https://ftp.debian.org/debian/pool/main/n/netselect/netselect_${NETSELECT_VERSION}_amd64.deb"}
    NETSELECT_DEB=${NETSELECT_URI}

    if [ ! -f "${NETSELECT_URI}" ]; then
        NETSELECT_DEB=$(mktemp)

        echo -n "Downloading netselect... "
        wget -qO "${NETSELECT_DEB}" "${NETSELECT_URI}"
        RES=$?

        if [ ! -f "${NETSELECT_DEB}" ]; then
            echo "ERROR: Got [${RES}] while downloading netselect. Bailing."
            exit 254
        else
            echo "OK"
        fi
    fi

    echo -n "Installing netselect... "

    if ! sudo dpkg -i "${NETSELECT_DEB}" >/dev/null 2>&1; then
        echo "ERROR: Got [$?] while installing netselect. Bailing."
        rm -f "${NETSELECT_DEB}"
        exit 253
    else
        echo "OK"
        rm -f "${NETSELECT_DEB}"
    fi
fi

EXCLUDE_HOSTS=$(grep -E ^deb /etc/apt/sources.list | awk -F'/' '{ print $3 }' | sort -u | xargs | sed 's/ /|/g')

echo -n "Finding mirrors... "
# shellcheck disable=SC2086
MIRRORS_DATA=$(wget -qO - ${MIRROR_URIS} | grep -v "${EXCLUDE_HOSTS}" | grep https | xargs)
echo "OK"

echo -n "Generating new mirrors file... "
# shellcheck disable=SC2086
sudo netselect -s ${MIRROR_MAX_MIRRORS} -t 40 ${MIRRORS_DATA} | awk '{ print $2 }' | head -n ${MIRROR_MAX_MIRRORS} | while read -r MIRROR_URL; do
    for MIRROR_CHANNEL in ${MIRROR_CHANNELS}; do
        echo "deb ${MIRROR_URL} ${MIRROR_CHANNEL} ${MIRROR_REPOS}"
    done
done | sudo tee "${MIRROR_LIST_FILE}.new" >/dev/null 2>&1
echo "OK"

if [ ! -f "${MIRROR_LIST_FILE}" ]; then
    echo -n "Creating mirrors.list file... "
    sudo mv "${MIRROR_LIST_FILE}.new" "${MIRROR_LIST_FILE}"
elif ! diff "${MIRROR_LIST_FILE}" "${MIRROR_LIST_FILE}.new" >"${MIRROR_VERBOSE_OUTPUT}" 2>&1; then
    echo -n "Updating mirrors.list file... "
    sudo cp "${MIRROR_LIST_FILE}" "${MIRROR_LIST_FILE}.save"
    sudo mv "${MIRROR_LIST_FILE}.new" "${MIRROR_LIST_FILE}"
else
    echo -n "No changes needed..."
    sudo rm "${MIRROR_LIST_FILE}.new"
fi

echo "OK"
