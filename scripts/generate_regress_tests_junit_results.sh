#!/bin/bash

# Pure bash script to convert PostgreSQL .out files to JUnit XML
# Simple and robust approach using awk

set -e

# Global variables
SCRIPT_NAME="$(basename "$0")"
VERBOSE=0
DEBUG=0
OUTPUT_FILE="test-results.xml"
PROCESS_ALL=0
SPECIFIC_FILE=""
SEARCH_DIR="."
RESULT_DIR="."
SEARCH_FILENAME="summary*.out"

# Logging functions
log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "$@" >&2
    fi
}

log_debug() {
    if [[ $DEBUG -eq 1 ]]; then
        echo "DEBUG: $@" >&2
    fi
}

log_error() {
    echo "Error: $@" >&2
}

# Help function
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Convert PostgreSQL test output files to JUnit XML format.

OPTIONS:
    -f, --file FILE         Process specific file
    -a, --all               Process all matching files found in directory tree
    -n, --name FILENAME     Filename pattern to search for, supports wildcards (default: summary*.out)
    -d, --directory DIR     Root directory to search (default: current directory)
    -o, --output FILE       Output XML file path (default: test-results.xml)
    -r, --result-dir DIR    Directory to write test results to (default: current directory)
    -v, --verbose           Enable verbose output
    --debug                 Enable debug output (shows file contents and regex matching)
    -h, --help              Show this help message

EXAMPLES:
    # Convert specific file (uses default output)
    $SCRIPT_NAME -f summary.out
    
    # Find and convert all summary*.out files
    $SCRIPT_NAME -a -o all_results.xml
    
    # Search for regression.out instead of summary*.out
    $SCRIPT_NAME -a -n regression.out
    
    # Search for all .out files
    $SCRIPT_NAME -a -n "*.out"
    
    # Write results to specific directory
    $SCRIPT_NAME -a -r ./test-output
    
    # Search specific directory with verbose output
    $SCRIPT_NAME -a -d /path/to/workspace -o results.xml -v

EOF
}

# XML utility function
xml_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&#39;}"
    echo "$text"
}

# Parse .out files and generate XML
process_files() {
    local files=("$@")
    
    # Create temporary file for collecting test data
    local temp_file=$(mktemp)
    trap "rm -f '$temp_file'" EXIT
    
    local total_tests=0
    local total_failures=0
    local total_time=0
    
    # Process each file
    local files_processed=0
    for file_path in "${files[@]}"; do
        if [[ ! -f "$file_path" ]]; then
            log_error "File not found: $file_path"
            continue
        fi
        
        files_processed=$((files_processed + 1))
        log_verbose "Processing: $file_path"

        # Check if there's a regression.diffs in the parent directory
        local diffs_file="$(dirname "$file_path")/../regression.diffs"
        declare -A diffs_map
        if [[ -f "$diffs_file" ]]; then
            log_verbose "Found diffs file: $diffs_file"
            
            # Parse regression.diffs file and build a map of test_name -> diff_output
            # Format: diff -dU10 /path/to/expected/TESTNAME.out /path/to/results/TESTNAME.out
            local current_test=""
            local current_diff=""
            
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Check if this is a new diff header line
                if [[ "$line" =~ ^diff[[:space:]]+-dU[0-9]+[[:space:]]+.*/expected/(multinode/[^/]+|[^/]+)\.out ]]; then
                    # Save previous test's diff if we had one
                    if [[ -n "$current_test" && -n "$current_diff" ]]; then
                        diffs_map["$current_test"]="$current_diff"
                        log_verbose "Stored diff for test: $current_test (${#current_diff} chars)"
                    fi
                    
                    # Extract test name from the path (remove .out.modified if present)
                    current_test="${BASH_REMATCH[1]}"
                    current_test="${current_test%.modified}"
                    current_diff="$line"
                    log_verbose "Found diff for test: $current_test"
                elif [[ -n "$current_test" ]]; then
                    # Append line to current diff (limit size to avoid memory issues)
                    if [[ ${#current_diff} -lt 10000 ]]; then
                        current_diff+=$'\n'"$line"
                    elif [[ ${#current_diff} -eq 10000 ]]; then
                        current_diff+=$'\n'"... (diff truncated)"
                    fi
                fi
            done < "$diffs_file"
            
            # Don't forget to save the last test's diff
            if [[ -n "$current_test" && -n "$current_diff" ]]; then
                diffs_map["$current_test"]="$current_diff"
                log_verbose "Stored diff for test: $current_test (${#current_diff} chars)"
            fi
            
            log_verbose "Parsed ${#diffs_map[@]} test diffs from $diffs_file"
        fi
        
        # Write diffs_map to a temp file for awk to read
        # Format: test_name<TAB>base64_encoded_diff
        local diffs_temp_file=$(mktemp)
        for test_name in "${!diffs_map[@]}"; do
            # Base64 encode the diff to handle special characters and newlines
            local encoded_diff
            encoded_diff=$(echo "${diffs_map[$test_name]}" | base64 -w 0)
            printf '%s\t%s\n' "$test_name" "$encoded_diff" >> "$diffs_temp_file"
        done
        
        # Debug: Show file info and sample content
        if [[ $DEBUG -eq 1 ]]; then
            log_debug "File size: $(wc -c < "$file_path") bytes"
            log_debug "File lines: $(wc -l < "$file_path")"
            log_debug "First 10 lines:"
            head -10 "$file_path" | sed 's/^/DEBUG: |/' >&2
            log_debug "Last 10 lines:"
            tail -10 "$file_path" | sed 's/^/DEBUG: |/' >&2
            log_debug "Lines containing test patterns:"
            grep -E "test.*\.\.\.|\.\.\.*ok|\.\.\.*FAILED|\.\.\.*PASSED|^ok [0-9]|^not ok [0-9]" "$file_path" | head -5 | sed 's/^/DEBUG: PATTERN|/' >&2 || log_debug "No pattern matches found"
        fi

        # Use awk to parse the file
        awk -v file_path="$file_path" -v verbose="$VERBOSE" -v debug="$DEBUG" -v diffs_file="$diffs_temp_file" '
        BEGIN {
            file_tests = 0
            file_failures = 0
            file_time = 0
            total_lines = 0
            matched_lines = 0
            
            # Load diffs map from temp file (test_name<TAB>base64_encoded_diff)
            while ((getline diff_line < diffs_file) > 0) {
                split(diff_line, diff_parts, "\t")
                diffs[diff_parts[1]] = diff_parts[2]
                if (debug == 1) {
                    printf "DEBUG: Loaded diff for test: %s\n", diff_parts[1] > "/dev/stderr"
                }
            }
            close(diffs_file)
        }
        
        {
            total_lines++
            if (debug == 1 && total_lines <= 20) {
                printf "DEBUG: Line %d: [%s]\n", total_lines, $0 > "/dev/stderr"
            }
        }
        
        # Skip empty lines, parallel group headers, and hash comments
        /^$/ { next }
        /^parallel group/ { next }
        /^#/ { next }
        
        # Match test lines: optional spaces, optional "test ", path-like test_name, " ... ", status, duration, "ms"
        /^[[:space:]]*(test[[:space:]]+)?[A-Za-z_][A-Za-z0-9_\.\/-]*[[:space:]]+\.\.\.[[:space:]]+[A-Za-z]+[[:space:]]+[0-9]+[[:space:]]+ms[[:space:]]*$/ {
            matched_lines++
            if (debug == 1) {
                printf "DEBUG: MATCHED line %d: [%s]\n", NR, $0 > "/dev/stderr"
            }
            
            # Extract test name - remove leading spaces and optional "test "
            test_line = $0
            gsub(/^[[:space:]]*/, "", test_line)
            gsub(/^test[[:space:]]+/, "", test_line)
            
            # Split on " ... " to get test name and result
            split(test_line, parts, /[[:space:]]+\.\.\.[[:space:]]+/)
            test_name = parts[1]
            
            # Parse status and duration from second part
            result_part = parts[2]
            split(result_part, result_fields, /[[:space:]]+/)
            status = result_fields[1]
            duration = result_fields[2]
            
            # Convert to seconds
            duration_sec = duration / 1000.0
            
            # Update counters
            file_tests++
            file_time += duration
            if (status != "ok") {
                file_failures++
            }
            
            if (debug == 1) {
                printf "DEBUG: Parsed - name:[%s] status:[%s] duration:[%s] duration_sec:[%.3f]\n", test_name, status, duration, duration_sec > "/dev/stderr"
            }

            # Look up diff output from diffs map (base64 encoded)
            if (test_name in diffs) {
                diff_output = diffs[test_name]
                if (debug == 1) {
                    printf "DEBUG: Found diff for test: %s\n", test_name > "/dev/stderr"
                }
            } else {
                diff_output = ""
            }
            
            # Output in pipe-separated format for later processing
            printf "%s|%s|%.3f|%d|%s|%s\n", test_name, status, duration_sec, duration, file_path, diff_output
            
            if (verbose == 1) {
                printf "  Found test: %s (%s, %dms)\n", test_name, status, duration > "/dev/stderr"
            }
        }
        
        # Match new TAP format: "ok"/"not ok" number "-"/"+" path-like test_name duration "ms"
        /^(ok|not ok)[[:space:]]+[0-9]+[[:space:]]*[-+][[:space:]]*[A-Za-z_][A-Za-z0-9_\.\/-]*[[:space:]]+[0-9]+[[:space:]]+ms[[:space:]]*$/ {
            matched_lines++
            if (debug == 1) {
                printf "DEBUG: MATCHED TAP format line %d: [%s]\n", NR, $0 > "/dev/stderr"
            }
            
            # Parse TAP format: ok/not ok number - test_name duration ms
            # Determine status from the beginning
            if ($0 ~ /^ok/) {
                status = "ok"
            } else {
                status = "failed"
            }
            
            # Extract test name and duration
            test_line = $0
            gsub(/^(ok|not ok)[[:space:]]+[0-9]+[[:space:]]*[-+][[:space:]]*/, "", test_line)
            split(test_line, tap_parts, /[[:space:]]+/)
            test_name = tap_parts[1]
            duration = tap_parts[2]
            
            # Convert to seconds
            duration_sec = duration / 1000.0
            
            # Update counters
            file_tests++
            file_time += duration
            if (status != "ok") {
                file_failures++
            }
            
            # Get file path and remove ./
            file_path_clean = file_path
            gsub(/^\.\//, "", file_path_clean)
            
            if (debug == 1) {
                printf "DEBUG: TAP format - name:[%s] status:[%s] duration:[%s] duration_sec:[%.3f]\n", test_name, status, duration, duration_sec > "/dev/stderr"
            }

            # Look up diff output from diffs map (base64 encoded)
            if (test_name in diffs) {
                diff_output = diffs[test_name]
                if (debug == 1) {
                    printf "DEBUG: Found diff for test: %s\n", test_name > "/dev/stderr"
                }
            } else {
                diff_output = ""
            }
            
            # Output in pipe-separated format for later processing
            printf "%s|%s|%.3f|%d|%s|%s\n", test_name, status, duration_sec, duration, file_path_clean, diff_output
            
            if (verbose == 1) {
                printf "  Found test: %s (%s, %dms)\n", test_name, status, duration > "/dev/stderr"
            }
        }
        
        END {
            if (debug == 1) {
                printf "DEBUG: Processed %d total lines, %d matched pattern, %d tests found\n", total_lines, matched_lines, file_tests > "/dev/stderr"
            }
            if (verbose == 1) {
                printf "  Found %d test results (%d failures)\n", file_tests, file_failures > "/dev/stderr"
            }
        }' "$file_path" >> "$temp_file" || true
        
        # Cleanup diffs temp file
        rm -f "$diffs_temp_file"
    done
    
    # Check if we processed any files
    if [[ $files_processed -eq 0 ]]; then
        log_error "No valid files matching pattern '$SEARCH_FILENAME' were processed"
        exit 1
    fi
    
    # Count totals
    if [[ -s "$temp_file" ]]; then
        total_tests=$(wc -l < "$temp_file" || echo "0")
        total_failures=$(awk -F'|' '$2 != "ok" {count++} END {print count+0}' "$temp_file" || echo "0")
        total_time=$(awk -F'|' '{sum += $4} END {printf "%.3f", sum/1000}' "$temp_file" || echo "0.000")
    else
        log_error "No test results found"
        rm -f "$temp_file"
        exit 1
    fi
    
    log_verbose "Generating JUnit XML with $total_tests tests, $total_failures failures, ${total_time}s total time"
    
    # Generate XML
    generate_xml "$temp_file" "$total_tests" "$total_failures" "$total_time"
    
    # Cleanup
    rm -f "$temp_file"
}

# Generate JUnit XML
generate_xml() {
    local temp_file="$1"
    local total_tests="$2"
    local total_failures="$3"
    local total_time="$4"
    
    # Create output directory if it doesn't exist
    local output_dir=$(dirname "$OUTPUT_FILE")
    if [[ ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir"
        log_verbose "Created output directory: $output_dir"
    fi
    
    # Generate timestamp in ISO 8601 format compatible with Azure DevOps
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Start XML output  
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuites tests="%d" failures="%d" time="%s" timestamp="%s">\n' \
            "$total_tests" "$total_failures" "$total_time" "$timestamp"
        
        # Group by file and generate test suites
        sort -t'|' -k5 "$temp_file" | awk -F'|' -v timestamp="$timestamp" -v search_dir="$SEARCH_DIR" '
        function xml_escape(text) {
            gsub(/&/, "\\&amp;", text)
            gsub(/</, "\\&lt;", text)
            gsub(/>/, "\\&gt;", text)
            gsub(/"/, "\\&quot;", text)
            gsub(/\x27/, "\\&#39;", text)
            return text
        }
        
        function decode_base64(encoded) {
            if (encoded == "") return ""
            cmd = "echo \"" encoded "\" | base64 -d 2>/dev/null"
            decoded = ""
            while ((cmd | getline line) > 0) {
                if (decoded != "") decoded = decoded "\n"
                decoded = decoded line
            }
            close(cmd)
            return decoded
        }
        
        BEGIN {
            current_file = ""
            suite_id = 0
        }
        
        {
            test_name = $1
            status = $2
            duration_sec = $3
            duration_ms = $4
            file_path = $5
            diff_output_encoded = $6
            
            # If new file, close previous suite and start new one
            if (file_path != current_file) {
                # Close previous suite
                if (current_file != "") {
                    printf "  </testsuite>\n"
                }
                
                current_file = file_path
                suite_name = file_path
                
                # Create more descriptive suite name from path
                # First, strip the search directory to make paths relative to repo root
                if (search_dir != "" && search_dir != ".") {
                    # Normalize search_dir path (remove trailing slash)
                    normalized_search = search_dir
                    gsub(/\/$/, "", normalized_search)
                    
                    # Create pattern to match search directory
                    search_pattern = "^" normalized_search "/"
                    gsub(/\//, "\\/", search_pattern)  # escape slashes for regex
                    
                    # Strip the search directory prefix
                    gsub(search_pattern, "", suite_name)
                }
                
                # Remove leading ./ and leading slashes, replace slashes with dots for better readability
                gsub(/^\.\//, "", suite_name)
                gsub(/^\/+/, "", suite_name)
                gsub(/\//, ".", suite_name)
                
                # If it ends with just "summary.out", make it more descriptive
                if (suite_name == "summary.out" || suite_name == "log.summary.out") {
                    suite_name = "regression_tests"
                }
                
                # Calculate suite statistics by reading the temp file again
                cmd = "awk -F'\''|'\'' '\''$5 == \"" file_path "\" {tests++; time+=$4; if($2 != \"ok\") failures++} END {printf \"%d %d %.3f\", tests, failures, time/1000}'\'' " "'"$temp_file"'"
                cmd | getline suite_stats
                close(cmd)
                
                split(suite_stats, stats, " ")
                suite_tests = stats[1]
                suite_failures = stats[2]
                suite_time = stats[3]
                
                # Start new testsuite with JUnit standard attributes
                suite_id++
                printf "  <testsuite name=\"%s\" tests=\"%d\" failures=\"%d\" time=\"%.3f\" timestamp=\"%s\">\n", \
                    xml_escape(suite_name), suite_tests, suite_failures, suite_time, timestamp
            }
            
            # Write testcase with JUnit standard attributes
            printf "    <testcase classname=\"%s\" name=\"%s\" time=\"%.3f\"", \
                xml_escape(suite_name), xml_escape(test_name), duration_sec
            
            if (status != "ok") {
                printf ">\n"
                # Decode base64 diff if present
                diff_output = decode_base64(diff_output_encoded)
                if (status == "FAILED" || status == "failed") {
                    if (diff_output != "") {
                        printf "      <failure message=\"Test %s failed\"><![CDATA[%s]]></failure>\n", \
                            xml_escape(test_name), diff_output
                    } else {
                        printf "      <failure message=\"Test %s failed\">Test %s failed in %s</failure>\n", \
                            xml_escape(test_name), xml_escape(test_name), xml_escape(file_path)
                    }
                } else {
                    printf "      <error message=\"Test %s had status: %s\">Test %s completed with status %s in %s</error>\n", \
                        xml_escape(test_name), xml_escape(status), xml_escape(test_name), xml_escape(status), xml_escape(file_path)
                }
                printf "    </testcase>\n"
            } else {
                printf " />\n"
            }
        }
        
        END {
            # Close final suite
            if (current_file != "") {
                printf "  </testsuite>\n"
            }
        }'
        
        printf '</testsuites>\n'
        
    } > "$OUTPUT_FILE"
    
    echo "JUnit XML written to $OUTPUT_FILE"
    
    # Debug: Show generated XML content
    if [[ $DEBUG -eq 1 ]]; then
        log_debug "Generated XML content:"
        sed 's/^/DEBUG: XML|/' "$OUTPUT_FILE" >&2
    fi
    
    echo ""
    echo "Summary:"
    echo "  Total tests: $total_tests"
    echo "  Passed: $((total_tests - total_failures))"
    echo "  Failed: $total_failures"
    echo "  Total time: ${total_time} seconds"
}

# Find test output files
find_regression_files() {
    local search_dir="$1"
    find "$search_dir" -name "$SEARCH_FILENAME" -type f 2>/dev/null
}

# Main function
main() {
    local files_to_process=()
    
    if [[ $PROCESS_ALL -eq 1 ]]; then
        log_verbose "Searching for files matching pattern '$SEARCH_FILENAME' in: $SEARCH_DIR"
        
        while IFS= read -r file; do
            files_to_process+=("$file")
        done < <(find_regression_files "$SEARCH_DIR")
        
        if [[ ${#files_to_process[@]} -eq 0 ]]; then
            log_error "No files matching pattern '$SEARCH_FILENAME' found in $SEARCH_DIR"
            exit 1
        fi
        
        log_verbose "Found ${#files_to_process[@]} files matching pattern '$SEARCH_FILENAME':"
        for file in "${files_to_process[@]}"; do
            log_verbose "  $file"
        done
        
    elif [[ -n "$SPECIFIC_FILE" ]]; then
        files_to_process=("$SPECIFIC_FILE")
    fi
    
    # Create result directory if it doesn't exist
    if [[ ! -d "$RESULT_DIR" ]]; then
        mkdir -p "$RESULT_DIR"
        log_verbose "Created result directory: $RESULT_DIR"
    fi
    
    # Convert relative output file to use result directory
    if [[ "$OUTPUT_FILE" != /* ]]; then
        OUTPUT_FILE="$RESULT_DIR/$OUTPUT_FILE"
    fi
    
    process_files "${files_to_process[@]}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            SPECIFIC_FILE="$2"
            shift 2
            ;;
        -a|--all)
            PROCESS_ALL=1
            shift
            ;;
        -n|--name)
            SEARCH_FILENAME="$2"
            shift 2
            ;;
        -d|--directory)
            SEARCH_DIR="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -r|--result-dir)
            RESULT_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate arguments
if [[ $PROCESS_ALL -eq 0 && -z "$SPECIFIC_FILE" ]]; then
    log_error "Must specify either --file or --all"
    show_help
    exit 1
fi

if [[ $PROCESS_ALL -eq 1 && -n "$SPECIFIC_FILE" ]]; then
    log_error "Cannot specify both --file and --all"
    show_help
    exit 1
fi

# Run main function
main

echo "Conversion completed successfully!"