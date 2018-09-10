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

if [[ -t 1 ]] && [[ $(tput colors) -ge 8 ]]; then
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
fi

function testrunner::function_declared() {
    test "$(type -t $1)" = 'function'
}

function testrunner::absolute_path() {
    printf "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

declare test_output_dir=$(mktemp -d)

function testrunner::run_tests() {
    local pretty_testsuite=$(basename $testsuite)
    local test_output_file="${test_output_dir}/${pretty_testsuite}.log"
    touch $test_output_file
    exec 4< $test_output_file

    local all_testcases=($(cat $testsuite | grep "function .*()" | grep -o "test_[a-zA-Z_]*"))
    local requested_testcases=$testcases
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
        printf "${kUnderline}No matching tests for '$requested_testcases' in ${testsuite}${kReset}\n\n"
        return;
    fi

    printf "${kUnderline}Running ${#testcases[@]} tests from ${pretty_testsuite}...${kReset}\n"

    if testrunner::function_declared setup; then
        setup >>$test_output_file 2>&1
    fi

    if [[ $DEBUG -eq 0 ]] || ! testrunner::print_test_output "Setup"; then
        printf "\n"
    fi

    local test_failure
    for testcase in "${testcases[@]}" ; do
        tests_total+=1

        local pretty_testcase=${testcase#test_}
        local pretty_testcase=${pretty_testcase//[_]/ }
        printf -- "- ${pretty_testcase} "

        test_failure=""
        trap 'testrunner::register_failure "$BASH_COMMAND" $?' ERR INT

        # Work around older bash versions not getting location correct on error
        set -o functrace
        local -a actual_lineno
        local -a actual_source
        trap 'actual_lineno+=($LINENO); actual_source+=(${BASH_SOURCE[0]})' DEBUG

        ${testcase} >>$test_output_file 2>&1
        trap - ERR INT DEBUG

        if [[ -z "$test_failure" ]]; then
            printf "${kGreen}✔${kReset}\n"

            if [[ $DEBUG -eq 1 ]]; then
                testrunner::print_test_output
            fi
        else
            tests_failed+=1
            printf "${kRed}✘${kReset}\n"

            IFS='|' read -r filename line_number expression \
                evaluated_expression exit_code <<< "$test_failure"

            testrunner::print_location $filename $line_number

            printf "Expression:\n\n"
            printf " ${kBold}${expression}${kReset}"
            if [[ $evaluated_expression != $expression ]]; then
                printf " (${evaluated_expression})"
            fi
            printf "\n\nFailed with exit code ${kBold}${exit_code}${kReset}\n"

            testrunner::print_test_output

            if [[ ${exit_code} -eq 130 ]]; then
                break; # Interrupted
            fi
        fi
    done

    if testrunner::function_declared teardown; then
        teardown >>$test_output_file 2>&1
    fi

    [[ $DEBUG -eq 1 ]] && testrunner::print_test_output "Teardown"

    if [[ -z "$test_failure" ]]; then
        printf "\n" # Blank line in case the last test passed
    fi

    exec 4>&-
}

set -o errtrace
function testrunner::register_failure() {
    trap - DEBUG
    if [[ ! -z "$test_failure" ]]; then
        return; # Already processing a failure
    fi
    #for (( f=${#actual_source[@]}; f >= 0; f-- )); do
    #    echo "${actual_source[$f]}:${actual_lineno[$f]}"
    #done
    local line=${actual_lineno[${#actual_lineno[@]} - 4]}
    local filename=${actual_source[${#actual_source[@]} - 5]}
    local command=$1
    local exit_code=$2
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

function testrunner::print_test_output {
    header=${1:-Output}
    local -i wrote_header=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ ! $wrote_header -eq 1 ]]; then
            printf "\n${header}:\n\n"
            wrote_header=1
        fi
        printf " ${kMagenta}|${kReset} $line\n"
    done <&4
    if [[ $wrote_header -eq 1 ]]; then
        printf "\n"
        return 0
    else
        return 1
    fi
}

function testrunner::signal_children() {
    signal=${1:-KILL}
    child_pids=($(ps -o pid= -g $$ | sort --reverse))
    # Remove first three (ps in subshell) and last (self)
    child_pids=("${child_pids[@]:3:${#child_pids[@]}-4}")
    for pid in "${child_pids[@]}"; do
        echo "Sending $signal to PID $pid ($(ps -o command= $pid))"
        kill -s $signal $pid >/dev/null 2>&1
    done
}

function testrunner::teardown() {
    testrunner::signal_children KILL
    rm -Rf $test_output_dir
}

function testrunner::print_summary() {
    if [[ $tests_failed -gt 0 || ($tests_total -eq 0 && ! -z "${testcases[@]}") ]]; then
        printf "${kRed}FAIL${kReset}"
    else
        printf "${kGreen}OK${kReset}"
    fi
    printf ": $tests_total tests"
    if [[ $tests_total -gt 0 ]]; then
        printf ", $tests_failed failures\n"
        return $tests_failed
    else
        printf "\n"
        return 1
    fi
}

trap 'testrunner::teardown; testrunner::print_summary; exit $?' EXIT

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
declare interrupted=0
trap 'interrupted=1' INT

printf "\n"
for testsuite in "${testsuites[@]}"; do
    exec 4>&1
    eval $(
        exec 3>&1 # Set up file descriptor for exporting variables
        exec 1>&4- # Ensure stdout still goes to the right place

        source "$testsuite"

        tests_total=0
        tests_failed=0
        testrunner::run_tests

        # Export results out of sub-shell
        printf "tests_total+=${tests_total}; tests_failed+=${tests_failed}" >&3

        # Clean up if test didn't do it
        testrunner::signal_children TERM >&2
    )
    exec 4>&-
    if [[ $interrupted -eq 1 ]]; then
        break;
    fi
done
