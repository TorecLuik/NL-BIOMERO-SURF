#!/bin/bash

# Default values
ENV_FILE="./.env"
OUTPUT_DIRECTORY=""
TIMESTAMP=""
METABASE_FOLDER=""
HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --output-directory)
            OUTPUT_DIRECTORY="$2"
            shift 2
            ;;
        --timestamp)
            TIMESTAMP="$2"
            shift 2
            ;;
        --metabase-folder)
            METABASE_FOLDER="$2"
            shift 2
            ;;
        --help)
            HELP=true
            shift
            ;;
        *)
            echo "[FAIL] Unknown parameter: $1"
            exit 1
            ;;
    esac
done

# Show help if requested
if [ "$HELP" = true ]; then
    cat << 'EOF'
METABASE BACKUP SCRIPT - Bash

USAGE:
  ./backup_and_restore/backup_metabase.sh [OPTIONS]

DESCRIPTION:
  Backs up the Metabase data folder containing the H2 database, configurations,
  and dashboard definitions. This preserves all custom dashboards, data sources,
  and user configurations.

PARAMETERS:
  --env-file <path>           Path to .env file (default: ./.env)
  --output-directory <dir>    Output directory (default: ./backup_and_restore/backups)
  --timestamp <timestamp>     Custom timestamp (default: auto-generated)
  --metabase-folder <path>    Path to metabase folder (default: ./metabase)
  --help                      Show this help message

EXAMPLES:
  # Standard backup
  ./backup_and_restore/backup_metabase.sh

  # Backup to specific directory
  ./backup_and_restore/backup_metabase.sh --output-directory "/backup"

  # Use custom timestamp (for coordination with other backups)
  ./backup_and_restore/backup_metabase.sh --timestamp "2025-01-15_10-30-00-UTC"

  # Custom metabase folder location
  ./backup_and_restore/backup_metabase.sh --metabase-folder "./custom-metabase"

OUTPUT FILES:
  metabase.{timestamp}.tar.gz - Contains entire metabase folder

WHAT'S BACKED UP:
  If Metabase is on Postgres (the default here since 2026-09), no folder exists
  and the script writes metabase.{timestamp}.pg_dump instead, dumped from the
  "metabase" database on database-biomero. Restore with pg_restore --clean.

  If Metabase is still on H2, the archive holds the folder:
  - metabase.db (H2 database with dashboards, users, settings)
  - metabase.db.mv.db (H2 database file)
  - metabase.db.trace.db (H2 trace file, if present)
  - Any custom configuration files
  - Plugin files (if any)

For more information, see: backup_and_restore/README.md
EOF
    exit 0
fi

# Set default values
FINAL_OUTPUT_DIR="${OUTPUT_DIRECTORY:-./backup_and_restore/backups}"
FINAL_METABASE_FOLDER="${METABASE_FOLDER:-./metabase}"
FINAL_TIMESTAMP="${TIMESTAMP:-$(date -u +%Y-%m-%d_%H-%M-%S-UTC)}"

# Create output directory
mkdir -p "$FINAL_OUTPUT_DIR"
ABSOLUTE_OUTPUT_DIR=$(realpath "$FINAL_OUTPUT_DIR")

# Since 2026-09 this deployment keeps Metabase's application database in
# Postgres (a "metabase" database on database-biomero), not in an H2 file, so
# there is no folder to archive. Dump the database instead. The folder path is
# still honoured when one exists, for deployments still on H2.
if [ ! -d "$FINAL_METABASE_FOLDER" ]; then
    MB_CONTAINER="${MB_DB_CONTAINER:-nl-biomero-database-biomero-1}"
    MB_DB="${MB_DB_NAME:-metabase}"
    MB_USER_PG="${MB_DB_USER:-biomero}"
    # CONTAINER_ENGINE lets a caller pass e.g. "sudo docker" where the socket
    # is root-only, as it is on this host.
    ENGINE_BIN="${CONTAINER_ENGINE:-$(command -v docker || command -v podman)}"

    if [ -n "$ENGINE_BIN" ] && $ENGINE_BIN exec "$MB_CONTAINER" \
         psql -U "$MB_USER_PG" -d "$MB_DB" -c '\q' >/dev/null 2>&1; then
        OUT="$ABSOLUTE_OUTPUT_DIR/metabase.$FINAL_TIMESTAMP.pg_dump"
        echo "Metabase is on Postgres; dumping the $MB_DB database instead of a folder."
        echo "  Container: $MB_CONTAINER"
        echo "  Target:    $OUT"
        if ! $ENGINE_BIN exec "$MB_CONTAINER" \
               pg_dump -Fc -U "$MB_USER_PG" -f "/tmp/metabase.dump" "$MB_DB"; then
            echo "[FAIL] pg_dump of $MB_DB failed"
            exit 1
        fi
        $ENGINE_BIN cp "$MB_CONTAINER:/tmp/metabase.dump" "$OUT"
        $ENGINE_BIN exec "$MB_CONTAINER" rm -f /tmp/metabase.dump
        echo "[ OK ] $(du -h "$OUT" | cut -f1) written to $OUT"
        echo "       restore with: pg_restore -U $MB_USER_PG -d $MB_DB --clean"
        exit 0
    fi

    echo "[FAIL] Metabase folder not found: $FINAL_METABASE_FOLDER"
    echo "       and the $MB_DB database was not reachable in $MB_CONTAINER"
    echo "       Ensure NL-BIOMERO is deployed or specify correct path with --metabase-folder"
    exit 1
fi

ABSOLUTE_METABASE_FOLDER=$(realpath "$FINAL_METABASE_FOLDER")

# Show configuration
echo "METABASE BACKUP CONFIGURATION"
echo "============================="
echo "  Timestamp: $FINAL_TIMESTAMP"
echo "  Metabase Folder: $ABSOLUTE_METABASE_FOLDER"
echo "  Output Directory: $ABSOLUTE_OUTPUT_DIR"
echo ""

# Check metabase folder contents
echo "Metabase folder contents:"
if [ -d "$ABSOLUTE_METABASE_FOLDER" ] && [ "$(ls -A "$ABSOLUTE_METABASE_FOLDER" 2>/dev/null)" ]; then
    for item in "$ABSOLUTE_METABASE_FOLDER"/*; do
        if [ -f "$item" ]; then
            size_mb=$(du -m "$item" | cut -f1)
            echo "  * $(basename "$item") (${size_mb} MB)"
        elif [ -d "$item" ]; then
            echo "  * $(basename "$item") (DIR)"
        fi
    done
else
    echo "  [WARN] Metabase folder is empty or inaccessible"
fi
echo ""

# Check if tar is available
if ! command -v tar &> /dev/null; then
    echo "[FAIL] tar command not found"
    echo "       tar is required for creating compressed archives"
    echo "       Please install tar"
    exit 1
fi

# Define output file
BACKUP_FILE_NAME="metabase.$FINAL_TIMESTAMP.tar.gz"
BACKUP_FILE_PATH="$ABSOLUTE_OUTPUT_DIR/$BACKUP_FILE_NAME"

echo "Starting Metabase backup..."
echo "  Source: $ABSOLUTE_METABASE_FOLDER"
echo "  Target: $BACKUP_FILE_PATH"
echo ""

# Change to parent directory of metabase folder for relative paths in archive
METABASE_FOLDER_NAME=$(basename "$ABSOLUTE_METABASE_FOLDER")
METABASE_PARENT_DIR=$(dirname "$ABSOLUTE_METABASE_FOLDER")

# Create tar archive with compression
echo "Creating compressed archive..."
cd "$METABASE_PARENT_DIR" || exit 1

if ! tar -czf "$BACKUP_FILE_PATH" "$METABASE_FOLDER_NAME"; then
    echo "[FAIL] tar command failed"
    exit 1
fi

# Check if backup file was created
if [ ! -f "$BACKUP_FILE_PATH" ]; then
    echo "[FAIL] Backup file was not created: $BACKUP_FILE_PATH"
    exit 1
fi

# Get backup file size
BACKUP_SIZE_MB=$(du -m "$BACKUP_FILE_PATH" | cut -f1)

echo ""
echo "METABASE BACKUP RESULTS"
echo "======================="
echo "  [OK] Backup completed successfully"
echo "  [OK] File: $BACKUP_FILE_NAME"
echo "  [OK] Size: ${BACKUP_SIZE_MB} MB"
echo "  [OK] Location: $ABSOLUTE_OUTPUT_DIR"
echo ""

# Verify archive contents (quick check)
echo "Archive contents verification:"
if tar -tzf "$BACKUP_FILE_PATH" >/dev/null 2>&1; then
    echo "  [OK] Archive is readable and contains:"
    tar -tzf "$BACKUP_FILE_PATH" | head -10 | while read -r line; do
        echo "    * $line"
    done
    
    # Show total number of files if more than 10
    total_files=$(tar -tzf "$BACKUP_FILE_PATH" | wc -l)
    if [ "$total_files" -gt 10 ]; then
        echo "    ... and $((total_files - 10)) more files"
    fi
else
    echo "  [WARN] Could not verify archive contents"
fi

echo ""
echo "[SUCCESS] Metabase backup completed successfully!"
echo ""


exit 0
