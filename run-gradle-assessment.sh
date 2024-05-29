#!/bin/bash
# set -x
#Copyright (c) 2024 Broadcom, Inc. All Rights Reserved.

# Default values
VERSION="1.1"
BUILD_DIR="."
OUTPUT_DIR="."
SKIP_GIT_INFO=false
VERBOSE=false

# internal variables
OUTPUT_TEMP_FILE="assessment-temp-data.json"
QUIET="-q"
GIT_VERBOSE=">/dev/null 2>&1"
PLUGIN_VERSION="0.8.1"
PROGRESS_CHAR=">"

# Function to display help message
display_help() {
  echo
  echo "Version: "$VERSION
  echo
  echo "Collect data to run spring health assessment"
  echo
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -b, --build-dir      Project build directory (default - current directory)"
  echo "  -o, --output-dir     Output directory location (default - current directory/assessment)"
  echo "  -s, --skip-gitinfo   Skip git info collection"
  echo "  -v, --verbose        Show verbose logs for troubleshooting"
  exit 0
}


progress_bar() {
  if [ "$VERBOSE" = false ]; then
    local count="$1"
    local str=$PROGRESS_CHAR
    for ((i = 0; i < count; i++)); do
        str=$str$PROGRESS_CHAR
    done
    echo -ne $str"[$count%]\r"
    sleep 1
  fi

}

# Function to print/log messages when verbose is enabled
verbose_log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $@" >> "$LOG_NAME"
  if [ "$VERBOSE" = true ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $@"
  fi
}

#verify command installed
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# log and execute
log_and_execute() {
  verbose_log "Executing command: $@"
  if [ "$VERBOSE" = true ]; then
    $@
  else
    $@ 2>>"$LOG_NAME" >&2
  fi

  if [ $? -ne 0 ]; then
     echo "$(date '+%Y-%m-%d %H:%M:%S'): Failed to run: $@" | tee -a "$LOG_NAME"
     exit 1
  fi
}

# log and run commands
log_and_command(){
  command_string=$1
  shift
  verbose_log "Executing command: $@"
  command_value=$($@)
  eval "$command_string=$command_value"
}


# Parse command line options
while [ "$#" -gt 0 ]; do
  case "$1" in
    -b|--build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    -o|--output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -s|--skip-gitinfo)
      SKIP_GIT_INFO=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      QUIET=""
      GIT_VERBOSE=""
      shift
      ;;
    -h|--help)
      display_help
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use $0 --help to display available options."
      exit 1
      ;;
  esac
done

if [ "$BUILD_DIR" = "." ]; then
  BUILD_DIR=$(pwd)
fi

if [ "$OUTPUT_DIR" = "." ]; then
  OUTPUT_DIR=$(pwd)
fi
OUTPUT_DIR="$OUTPUT_DIR/assessment"
mkdir -p $OUTPUT_DIR
cd $OUTPUT_DIR
OUTPUT_DIR=$(pwd)
LOG_NAME="$OUTPUT_DIR/assessment.log"

# Define the content of the Gradle build file
gradle_init_content=$(cat <<EOF
initscript {
    repositories {
        maven {
            url "https://plugins.gradle.org/m2/"
        }
    }
    dependencies {
        classpath "org.cyclonedx:cyclonedx-gradle-plugin:1.8.2"
    }
    configurations.classpath {
        resolutionStrategy {
            force("com.fasterxml.jackson.core:jackson-databind:2.14.0")
            force("com.fasterxml.jackson.core:jackson-core:2.14.0")
        }
    }
}

allprojects{
    afterEvaluate { project ->
        if (!project.findProperty("group") ){
            println 'Property group is not defined. Setting org.'+project.name
            setProperty("group","org."+project.name)
        }
        if (!project.findProperty("version") ){
            println 'Property version is not defined. Setting 0.0.1-SNAPSHOT'
            setProperty("version","0.0.1-SNAPSHOT")
        }
    }
    apply plugin:org.cyclonedx.gradle.CycloneDxPlugin
    cyclonedxBom {
        projectType = "application"
        schemaVersion = "1.4"
        destination = file("\${bomOutputDir}")
        outputName = project.name
        outputFormat = "json"
        includeBomSerialNumber = false
        includeLicenseText = true
        doLast{
            if ( project.getProperty('name')==rootProject.getProperty('name')){
                mkdir "\${bomOutputDir}/aggr"
                copy {
                    from "\${bomOutputDir}"
                    into "\${bomOutputDir}/aggr"
                    include rootProject.getProperty('name')+".json"
                }
            }
        }
    }
}
EOF
)

verbose_log "*****************************************************************************"
verbose_log "*                     Started SBOM Collection                               *"
verbose_log "*****************************************************************************"

# Check if Git is not installed
if ! command_exists "git"; then
  echo "Git is not installed. Please install Git and try again."
  exit 1
fi

progress_bar 20
log_and_execute cd "$BUILD_DIR"

gradle_file=$(find . -name 'build.gradle' -type f)
if [ -z "$gradle_file" ]; then
  echo "No build file (build.gradle) found in current directory. Please verify the project build directory"
  exit 1
fi

gradlew_file=$(find . -name 'gradlew' -type f)
if [ -z "$gradlew_file" ]; then
  echo "Gradle wrapper not exist. Create gradle wrapper (gradlew) using command: gradle wrapper "
  exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S'): Assessment data file generation started..."
progress_bar 30
echo "$gradle_init_content" > $OUTPUT_DIR/init.gradle
log_and_execute ./gradlew -I $OUTPUT_DIR/init.gradle cyclonedxBom -PbomOutputDir=$OUTPUT_DIR/sbom
log_and_execute rm -rf $OUTPUT_DIR/init.gradle
progress_bar 80

directory=$OUTPUT_DIR"/sbom/aggr"
GIT_DETAILS="}"
# Check if the .git folder exists
if [[ -d .git &&  "$SKIP_GIT_INFO" != true ]]; then
  log_and_command remote_url git config --get remote.origin.url
  log_and_command branch git symbolic-ref --short HEAD
  log_and_command commit_hash git rev-parse HEAD
  GIT_DETAILS=",\"git\":{\"git.remote.origin.url\":\"$remote_url\", \"git.branch\":\"$branch\", \"git.commit.id\":\"$commit_hash\"}}"
fi

# Iterate over each file in the directory
for file in "$directory"/*; do
    # Check if it's a regular file (not a directory)
    output_file=$OUTPUT_DIR/$(basename "$file")
    if [ -f "$file" ]; then
        echo '{"sbom":' > "$output_file"
        cat "$file" >> "$output_file"
        echo "$GIT_DETAILS" >> "$output_file"
    fi
done

progress_bar 90
log_and_execute rm -rf "$OUTPUT_DIR/sbom"
progress_bar 100
echo -ne '\n'

echo "$(date '+%Y-%m-%d %H:%M:%S'): The assessment data file is generated at $OUTPUT_DIR. Upload this file to assessment portal."