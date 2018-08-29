#!/usr/bin/env bash
#
#  Minimal test runner with pretty output
#
#  Copyright (c) 2018 Tor Arne Vestbø
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in all
#  copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
#  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
#  OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
#  OR OTHER DEALINGS IN THE SOFTWARE.
#
# ----------------------------------------------------------

declare -i counter=0
for color in Black Red Green Yellow Blue Magenta Cyan White; do
    declare -r k${color}="\033[$((30 + $counter))m"
    declare -r k${color}Background="\033[$((40 + $counter))m"
    counter+=1
done
declare -r kReset="\033[0m"
declare -r kBold="\033[1m"
declare -r kDark="\033[2m"
declare -r kUnderline="\033[4m"
declare -r kInverse="\033[7m"

function testrunner::function_declared() {
    test "$(type -t $1)" = 'function'
}

function testrunner::absolute_path() {
    echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

trap "echo INT" INT

function testrunner::run_tests() {
    local all_testcases=($(declare -f | grep -o "^test_[a-zA-Z_]*"))
    if [[ -z $testcases ]]; then
        testcases=("${all_testcases[@]}")
    else
        local -a matching_testcases
        for testcase in "${testcases[@]}" ; do
            if [[ "${all_testcases[@]}" =~ (^| )(test_)?${testcase}( |$) ]]; then
                matching_testcases+=(${BASH_REMATCH[0]})
            fi
        done
        testcases=("${matching_testcases[@]}")
    fi

    if [[ -z $testcases ]]; then
        printf "\n${kUnderline}No matching tests in ${testsuite}${kReset}\n"
        return;
    fi

    if testrunner::function_declared setup; then
        setup
    fi

    printf "\n${kUnderline}Running ${#testcases[@]} tests from ${testsuite}...${kReset}\n\n"

    local -i tests_total=0
    local -i tests_failed=0
    local test_failure
    for testcase in "${testcases[@]}" ; do
        tests_total+=1

        local pretty_testcase=${testcase#test_}
        local pretty_testcase=${pretty_testcase//[_]/ }
        echo -n "- ${pretty_testcase} "

        if ! testrunner::function_declared $testcase; then
            printf "${kRed}✘${kReset}\n"
            echo -e " (no such testcase)";
            tests_failed+=1
            continue;
        fi

        test_failure=""
        trap 'testrunner::register_failure "$BASH_COMMAND" $?' ERR
        ${testcase} >$test_output_file 2>&1
        trap - ERR

        if [[ -z "$test_failure" ]]; then
            printf "${kGreen}✔${kReset}\n"
        else
            tests_failed+=1
            printf "${kRed}✘${kReset}\n"

            IFS='|' read -ra failure <<< "$test_failure"

            local filename=$(testrunner::absolute_path ${failure[0]})
            local -i line_number=${failure[1]}
            local expression=${failure[2]}
            local evaluated_expression=${failure[3]}
            local exit_code=${failure[4]}

            testrunner::print_location $filename $line_number

            printf "Expression:\n\n"
            printf " ${kBold}${expression}${kReset}"
            if [[ $evaluated_expression != $expression ]]; then
                printf " (${evaluated_expression})"
            fi
            printf "\n\nFailed with exit code ${kBold}${exit_code}${kReset}\n"

            if [[ -s "$test_output_file" ]]; then
                printf "\nOutput:\n\n"
                while IFS='' read -r line || [[ -n "$line" ]]; do
                    printf " ${kMagenta}|${kReset} $line\n"
                done <$test_output_file
            fi

            printf "\n"
        fi
    done

    if testrunner::function_declared teardown; then
        teardown
    fi

    testrunner::teardown

    if [[ -z "$test_failure" ]]; then
        printf "\n" # Blank line in case the last test passed
    fi

    # Export results out of sub-shell
    echo "tests_total+=${tests_total}; tests_failed+=${tests_failed}" >&3
}

# Work around older bash versions not getting location correct on error
set -o functrace
declare -a actual_lineno
declare -a actual_source
trap 'actual_lineno+=($LINENO); actual_source+=(${BASH_SOURCE[0]})' DEBUG

set -o errtrace
function testrunner::register_failure() {
    # actual_lineno = [..., good, bad, --^, --v ]
    local line=${actual_lineno[${#actual_lineno[@]} - 4]}
    local filename=${actual_source[${#actual_source[@]} - 5]}
    local command=$1
    local exit_code=$2
    if [[ ! -z "$test_failure" ]]; then
        return; # Already processing a failure
    fi
    test_failure="${filename}|${line}|${command}|$(eval "echo ${command}")|${exit_code}"
}

function testrunner::print_location() {
    local filename=$1
    local line_number=$2

    printf "\n${kBlack}${kBold}${filename}:${line_number}${kReset}\n\n"

    local -r -i context_lines=2

    # FIXME: Start at function?
    local -i context_above=$context_lines
    local -i context_below=$context_lines
    test $context_above -ge $line_number && context_above=$(($line_number - 1))

    local -i diff_start=${line_number}-${context_above}
    local -i total_lines=$(($context_above + 1 + $context_below))
    local -i current_line=${diff_start}
    tail -n "+${diff_start}" ${filename} | head -n $total_lines | while IFS='' read -r line; do
        if [ $current_line -eq $line_number ]; then
            # FIXME: Compute longest line and color all the way
            printf " ${kRedBackground}${kBold}${current_line}:${kReset}${kRedBackground}"
        else
            printf " ${kBlack}${kBold}${current_line}:${kReset}"
        fi
        printf " ${line}${kReset}\n"
        current_line+=1
    done

    printf "\n"
}

trap 'testrunner::teardown; testrunner::print_summary; exit $?' EXIT

function testrunner::teardown() {
    pkill -P $BASHPID
}

function testrunner::print_summary() {
    if [[ $tests_failed -gt 0 || ($tests_total -eq 0 && ! -z "${testcases[@]}") ]]; then
        printf "${kRed}FAIL${kReset}"
    else
        printf "${kGreen}OK${kReset}"
    fi
    printf ": $tests_total tests"
    if [[ $tests_total -gt 0 ]]; then
        printf ", $tests_failed failures"
    fi
    printf "\n"
    return $tests_failed
}

# FIXME: Use pipes or other FDs instead of tmp file?
# FIXME: Split (but interleave) stdout and stderr?
declare test_output_file=$(mktemp)

declare -a testsuites
declare -a testcases
for argument in "$@"; do
    if [[ -f "$argument" ]]; then
        testsuites+=("$argument")
    else
        testcases+=("$argument")
    fi
done

declare -i tests_total=0
declare -i tests_failed=0
for testsuite in "${testsuites[@]}"; do
    exec 4>&1
    eval $( source "$testsuite" && testrunner::run_tests 3>&1 >&4- )
    exec 4>&-
done
