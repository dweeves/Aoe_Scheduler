#!/bin/bash

# Generate an error if any variable doesn't exist
set -o nounset

delete_lock() {
    LOCKDIR=$1
    rm -rf "${LOCKDIR}"
    if [ $? -ne 0 ]; then
        echo "Could not remove lock dir '${LOCKDIR}'. (Check permissions...)"; >&2
        exit 1;
    fi
}

# @see http://wiki.bash-hackers.org/howto/mutex
acquire_lock () {
    LOCKDIR=$1
    PIDFILE="${LOCKDIR}/PID"

    #echo "Trying to acquire lock '${LOCKDIR}'."
    if mkdir "${LOCKDIR}" &>/dev/null; then

        #echo "Successfully created '${LOCKDIR}'. Lock acquired"

        # lock succeeded
        trap 'delete_lock "${LOCKDIR}"; exit $?' INT TERM EXIT
        echo "$$" >"${PIDFILE}"
    else
        #echo "Failed creating ${LOCKDIR}."
        if [ ! -f "${PIDFILE}" ]; then
            #echo "No PID file found. Claiming lock now"
            delete_lock "${LOCKDIR}"
            # now try acquire new lock recursively...
            #echo "Now acquiring new lock"
            acquire_lock $LOCKDIR;
            return
        fi

        # lock failed, check if the other PID is alive
        OTHERPID="$(cat "${PIDFILE}")"
        # if cat isn't able to read the file, another instance is probably about to remove the lock -- exit, we're *still* locked
        if [ $? != 0 ]; then
            #echo "lock failed, PID ${OTHERPID} is active" >&2
            exit 1;
        fi

        # check is the other process is still alive
        if ! kill -0 $OTHERPID &>/dev/null; then
            # lock is stale, remove it and restart
            #echo "removing stale lock of nonexistant PID ${OTHERPID}" >&2
            delete_lock "${LOCKDIR}"
            # now try acquire new lock recursively...
            acquire_lock $LOCKDIR;
        else
            # lock is valid and OTHERPID is active - exit, we're locked!
            #echo "Other process is alive. Still locked"
            exit 1
        fi
    fi
}


# Location of the php binary
PHP_BIN=$(which php || true)
if [ -z "${PHP_BIN}" ]; then
    echo "Could not find a binary for php" 1>&2
    exit 1
fi

# Location of the md5sum binary
MD5SUM_BIN=$(which md5sum || true)
if [ -z "${MD5SUM_BIN}" ]; then
    echo "Could not find a binary for md5sum" 1>&2
    exit 1
fi

# Absolute path to Magento installation shell scripts
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/shell" && pwd)
if [[ -z "${DIR}" || ! -d "${DIR}" ]]; then
    echo "Could not resolve base shell directory" 1>&2
    exit 1
fi

# The scheduler.php script
SCHEDULER="scheduler.php"
if [[ ! -e "${DIR}/${SCHEDULER}" || ! -r "${DIR}/${SCHEDULER}" ]]; then
    echo "Could not find scheduler.php script" 1>&2
    exit 1
fi

# Defaults
MODE="default"
INCLUDE_GROUPS=""
EXCLUDE_GROUPS=""
INCLUDE_JOBS=""
EXCLUDE_JOBS=""

# Parse command line args (very simplistic)
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            MODE=$2
            shift 2
        ;;
        --includeGroups)
            INCLUDE_GROUPS=$2
            shift 2
        ;;
        --excludeGroups)
            EXCLUDE_GROUPS=$2
            shift 2
        ;;
        --includeJobs)
            INCLUDE_JOBS=$2
            shift 2
        ;;
        --excludeJobs)
            EXCLUDE_JOBS=$2
            shift 2
        ;;
        --)
            shift
            break
        ;;
        *)
            echo "Invalid arguments." >&2
            exit 1
        ;;
    esac
done

# Verify we have a MODE parameter
if [ -z "${MODE}" ]; then
    echo "Cron run mode MUST be defined." 1>&2
    exit 1
fi

# Lock process to one run per set of options
# This is to prevent multiple processes for the same cron parameters (And the only reason we don't call PHP directly)

# Unique identifier for this cron job run
IDENTIFIER=$(echo -n "${DIR}|${MODE}|${INCLUDE_GROUPS}|${EXCLUDE_GROUPS}|${INCLUDE_JOBS}|${EXCLUDE_JOBS}" | "${MD5SUM_BIN}" - | cut -f1 -d' ')
acquire_lock "/tmp/magento.aoe_scheduler.${IDENTIFIER}.lock";

# Needed because PHP resolves symlinks before setting __FILE__
cd "${DIR}"

# Build the options
OPTIONS=""
if [ -n "${INCLUDE_GROUPS}" ]; then
    OPTIONS="${OPTIONS} --includeGroups ${INCLUDE_GROUPS}"
fi
if [ -n "${EXCLUDE_GROUPS}" ]; then
    OPTIONS="${OPTIONS} --excludeGroups ${EXCLUDE_GROUPS}"
fi
if [ -n "${INCLUDE_JOBS}" ]; then
    OPTIONS="${OPTIONS} --includeJobs ${INCLUDE_JOBS}"
fi
if [ -n "${EXCLUDE_JOBS}" ]; then
    OPTIONS="${OPTIONS} --excludeJobs ${EXCLUDE_JOBS}"
fi

# Run the job in the foreground
"${PHP_BIN}" "${SCHEDULER}" --action cron --mode ${MODE} ${OPTIONS}
