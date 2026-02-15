#!/bin/bash
#
# run_tests.sh — Run UI tests for NexusPVR and DispatcherPVR across all platforms
#
# Usage:
#   ./run_tests.sh              # Run all tests (both schemes, all platforms)
#   ./run_tests.sh nexus        # NexusPVR only
#   ./run_tests.sh dispatcher   # DispatcherPVR only
#   ./run_tests.sh nexus macos  # NexusPVR macOS only
#

set -euo pipefail

# --- Configuration ---
SCHEMES=("NexusPVR" "DispatcherPVR")
DESTINATIONS=(
    "platform=macOS"
    "platform=iOS Simulator,name=iPhone 17 Pro"
    "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)"
)
DEST_LABELS=("macOS" "iOS" "tvOS")

# --- Parse arguments ---
FILTER_SCHEME=""
FILTER_PLATFORM=""

if [[ ${1:-} == "nexus" ]]; then
    FILTER_SCHEME="NexusPVR"
elif [[ ${1:-} == "dispatcher" ]]; then
    FILTER_SCHEME="DispatcherPVR"
fi

if [[ ${2:-} == "macos" ]]; then
    FILTER_PLATFORM="macOS"
elif [[ ${2:-} == "ios" ]]; then
    FILTER_PLATFORM="iOS"
elif [[ ${2:-} == "tvos" ]]; then
    FILTER_PLATFORM="tvOS"
fi

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Cleanup on interrupt ---
cleanup() {
    echo -e "\n${RED}Interrupted — killing xcodebuild...${NC}"
    pkill -P $$ 2>/dev/null || true
    pkill -f "xcodebuild.*test" 2>/dev/null || true
    exit 130
}
trap cleanup INT TERM

# --- State ---
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
declare -a RESULTS=()

log_header() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_result() {
    local scheme=$1 platform=$2 status=$3 duration=$4
    if [[ $status == "PASS" ]]; then
        echo -e "  ${GREEN}✓${NC} ${scheme} / ${platform}  ${BOLD}${GREEN}PASSED${NC}  (${duration}s)"
        RESULTS+=("${GREEN}✓  ${scheme} / ${platform} — PASSED (${duration}s)${NC}")
    elif [[ $status == "FAIL" ]]; then
        echo -e "  ${RED}✗${NC} ${scheme} / ${platform}  ${BOLD}${RED}FAILED${NC}  (${duration}s)"
        RESULTS+=("${RED}✗  ${scheme} / ${platform} — FAILED (${duration}s)${NC}")
    else
        echo -e "  ${YELLOW}–${NC} ${scheme} / ${platform}  ${BOLD}${YELLOW}SKIPPED${NC}"
        RESULTS+=("${YELLOW}–  ${scheme} / ${platform} — SKIPPED${NC}")
    fi
}

run_test() {
    local scheme=$1
    local destination=$2
    local label=$3

    TOTAL=$((TOTAL + 1))

    echo -e "\n${YELLOW}▸ Testing ${BOLD}${scheme}${NC}${YELLOW} on ${BOLD}${label}${NC}"

    local log_file
    log_file=$(mktemp /tmp/test_${scheme}_${label}_XXXXXX).log

    # Remove stale result bundle from previous runs
    rm -rf "/tmp/TestResults_${scheme}_${label}.xcresult"

    local start_time
    start_time=$(date +%s)

    if xcodebuild test \
        -scheme "$scheme" \
        -destination "$destination" \
        -resultBundlePath "/tmp/TestResults_${scheme}_${label}.xcresult" \
        2>&1 | tee "$log_file" | grep -E '(Test Suite|Test Case|Executed|FAILED|PASSED|error:)'; then

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_result "$scheme" "$label" "PASS" "$duration"
        PASSED=$((PASSED + 1))
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_result "$scheme" "$label" "FAIL" "$duration"
        FAILED=$((FAILED + 1))
        echo -e "  ${RED}Log: ${log_file}${NC}"
    fi
}

# --- Main ---
log_header "NexusPVR Test Runner"
echo -e "  Schemes:   ${FILTER_SCHEME:-all}"
echo -e "  Platforms:  ${FILTER_PLATFORM:-all}"
echo ""

OVERALL_START=$(date +%s)

for scheme in "${SCHEMES[@]}"; do
    # Filter by scheme
    if [[ -n $FILTER_SCHEME && $scheme != "$FILTER_SCHEME" ]]; then
        continue
    fi

    for i in "${!DESTINATIONS[@]}"; do
        dest="${DESTINATIONS[$i]}"
        label="${DEST_LABELS[$i]}"

        # Filter by platform
        if [[ -n $FILTER_PLATFORM && $label != "$FILTER_PLATFORM" ]]; then
            continue
        fi

        run_test "$scheme" "$dest" "$label"
    done
done

OVERALL_END=$(date +%s)
OVERALL_DURATION=$((OVERALL_END - OVERALL_START))

# --- Summary ---
log_header "Results"

for result in "${RESULTS[@]}"; do
    echo -e "  $result"
done

echo ""
echo -e "  ${BOLD}Total: ${TOTAL}  |  Passed: ${GREEN}${PASSED}${NC}  |  Failed: ${RED}${FAILED}${NC}  |  Duration: ${OVERALL_DURATION}s${NC}"

if [[ $FAILED -gt 0 ]]; then
    echo -e "\n  ${RED}${BOLD}SOME TESTS FAILED${NC}"
    exit 1
else
    echo -e "\n  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    exit 0
fi
