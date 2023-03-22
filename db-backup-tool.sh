#!/bin/bash

# Initialize variables with default values
CONFIG_DIRECTORY=/etc/db-backup
HELP_FLAG=0

# Define function to print out help message
print_help() {
    cat <<EOF
Usage: $0 [-h] [-r retention_policy] [config_name]

Creates a backup of all databases specified in the configuration file.

Positional arguments:
  config_name          Name of the configuration to use. If not specified, all files in the configurations directory with the .cfg extension will be used.

Optional arguments:
  -c, --config-dir            The path to directory containing configurations. (default: $CONFIG_DIRECTORY)
  -r, --retention POLICY      Retention policy type. Possible values: daily, weekly, monthly, yearly. If set, the value will be used as a suffix in the subdirectory name.
  -h, --help                  Print this help message and exit.

This script reads configuration files from the "config" directory located in the same directory as the script.

The configuration files are shell scripts that define the following variables:
  - DB_NAMES        An array of MySQL database names to backup
  - DB_HOST         The hostname or IP address of the MySQL server
  - DB_PORT         The port number of the MySQL server
  - DB_USER         The username to use when connecting to the MySQL server
  - DB_PASSWORD     The password to use when connecting to the MySQL server
  - BACKUP_DIR      The directory where the backups will be stored

Examples:
  $0                  # Creates a backup using all the configuration files.
  $0 mydb             # Creates a backup using the specified configuration file "mydb.cfg".
  $0 -r daily         # Creates a backup using all the configuration files and use a "daily" retention policy.
  $0 -r weekly mydb   # Creates a backup using the specified configuration file "mydb.cfg" and use a "weekly" retention policy.
  $0 -h               # Prints this help message.
EOF
}

# Loop through options and assign values
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--config-dir)
            CONFIG_DIRECTORY="$2"
            shift
            ;;
        -r|--retention)
            RETENTION_POLICY="$2"
            shift
            ;;
        -h|--help)
            HELP_FLAG=1
            ;;
        -*)
            # If unknown option or argument is given, print help message and exit
            print_help
            exit 1
            ;;
    esac
    shift
done

# If help flag is set, print help message and exit
if [ $HELP_FLAG -eq 1 ]; then
    print_help
    exit 0
fi

# Get the config file(s) to use
if [ $# -eq 0 ]; then
    CONFIG_FILES="$CONFIG_DIRECTORY/*.cfg"
else
    CONFIG_FILES="$CONFIG_DIRECTORY/$1.cfg"
fi

# Validate retention policy option
if [[ -v RETENTION_POLICY ]] && \
   ! [[ $RETENTION_POLICY =~ ^(daily|weekly|monthly|yearly)$ ]]; then
    echo "Error: Invalid retention policy option. Valid options are 'daily', 'weekly', 'monthly', or 'yearly'." >&2
    exit 1
fi

# Loop through each config file
# shellcheck disable=SC2068
for CONFIG_FILE in ${CONFIG_FILES[@]}; do

    CONFIG_NAME=$(basename "$CONFIG_FILE" | cut -d'.' -f1)

    # Check if the config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file $CONFIG_FILE not found." >&2
        exit 1
    fi

    echo -e "\nProcessing config file: $CONFIG_FILE"

    # Read config file
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Check if the backup destination directory exists
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Error: Backup destination directory $BACKUP_DIR not found." >&2
        exit 1
    fi

    # Delete old backups
    find $BACKUP_DIR -name "*.sql.gz" -mtime +$KEEP_BACKUPS_DAYS -type f -delete

    # Create backup subdirectory
    DATE_TIME=$(date +"%Y-%m-%d_%H%M%S")
    if [ -n "$RETENTION_POLICY" ]; then
        BACKUP_SUBDIR="${BACKUP_SUBDIR_PREFIX}_${DATE_TIME}_${RETENTION_POLICY}"
    else
        BACKUP_SUBDIR="${BACKUP_SUBDIR_PREFIX}_${DATE_TIME}"
    fi
    BACKUP_SUBDIR_FULL="$BACKUP_DIR/$BACKUP_SUBDIR"
    mkdir -p "$BACKUP_SUBDIR_FULL"

    # Initialize the array to store failed backups' information
    FAILED_BACKUPS=()

    # Backup each database
    for DB in "${DB_NAMES[@]}"; do
        # Create backup file name
        FILENAME="$DB.$DATE_TIME.sql.gz"
        BACKUP_FILE="$BACKUP_SUBDIR_FULL/$FILENAME"

        # Print backup start message
        echo -n "Database: $DB ... "

        # Run mysqldump to create backup
        mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" --single-transaction --routines --triggers --events "$DB" | gzip > "$BACKUP_FILE"

        # Print backup end message
        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            echo -e "\033[32mdone\033[0m"
        else
            # Add failed backup's information to the array
            FAILED_BACKUPS+=("$CONFIG_NAME.$DB")

            echo -e "\033[31mfailed\033[0m"
        fi

    done

    # Print completion message
    echo "Backups of $CONFIG_NAME completed to: $BACKUP_SUBDIR_FULL"

done

# Print out the number of failed backups and their information (if any)
if [ ${#FAILED_BACKUPS[@]} -eq 0 ]; then
    echo -e "\nAll database backups completed successfully."
else
    echo -e "\n${#FAILED_BACKUPS[@]} backups failed:"
    for failed_backup in "${FAILED_BACKUPS[@]}"; do
        echo "$failed_backup"
    done
fi
