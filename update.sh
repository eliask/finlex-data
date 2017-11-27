#! /usr/bin/env bash
set -euo pipefail

base=http://data.finlex.fi
curl -fs "$base"/data/xml/{asd,kho,kko}.html \
     | pup 'a[href^=/data/xml] attr{href}' \
     | sed "s#^#$base#" \
     > archives.list 

if grep -F '|' archives.list; then
     echo "No archives from server" >&2
     exit 1
fi

# Sort by archive date
< archives.list \
    sed 's#^\(.*\)/\([^0-9]*\)\([^/.]*\)\(\..*\)$#\1/\2\3\4|\3#' \
    | sort -t'|' -k2 \
    | sed 's#|.*##' \
    > sorted_archive_urls.list

import_zip() {
    if [[ $# != 2 ]]; then
        echo "Usage: import_zip filename update_timestamp" >&2
        exit 1
    fi
    zipfile=$1
    update_timestamp=$2
    [[ -n $update_timestamp ]]
    [[ -s $zipfile ]]

    update_timestamp=$(date --rfc-3339=seconds -d "$update_timestamp")

    dir=$(mktemp -d)
    cleanup() { rm -rf "$dir"; }
    trap cleanup EXIT
    unzip -qq -d "$dir" "$zipfile"

    # NB. using GNU stat.
    # NB2. pipefail must be disabled since we don't read the whole output from sort.
    newest_ctime=$(set +o pipefail; find "$dir" -type f -exec stat -c %W {} + | sort -rn | head -n1)
    timestamp=$(TZ=Europe/Helsinki date -R -d "@${newest_ctime}")
    rsync -a "$dir"/ data/

    git add data/
    GIT_COMMITTER_DATE=$timestamp \
    GIT_AUTHOR_DATE=$timestamp \
    git commit --allow-empty -m "Import $(basename "$zipfile") as of $update_timestamp"
}

mkdir -p data/
mkdir -p archives/
touch archives/.dummy

while read -r url; do
    file=$(basename "$url")
    file_path=archives/$file
 
    if [[ -s "$file_path".metadata ]]; then
        etag=$(grep -i ^ETag: "$file_path".metadata | sed 's/^ETag: //i')
        timestamp=$(grep -i ^Last-Modified: "$file_path".metadata | sed 's/^Last-Modified: //i')
    else
        etag=
        timestamp=
    fi

    curl -fsI "$url" |
        grep -iE '^(ETag|Last-Modified): ' \
        > "$file_path".metadata.new

    new_etag=$(grep -i ^ETag: "$file_path".metadata.new | sed 's/^ETag: //i')
    new_timestamp=$(grep -i ^Last-Modified: "$file_path".metadata.new | sed 's/^Last-Modified: //i')
    if [[ $new_etag = "$etag" ]] && [[ $new_timestamp = "$timestamp" ]]; then
        echo "File has not changed from server: $file -- Skipping."
        rm "$file_path".metadata.new
        continue
    fi

    # NB: The origin server is buggy and crashes with 503
    # so we opt to not use these headers in GET requests.
    #    --header "If-None-Match: $etag" \
    #    --header "If-Modified-Since: $timestamp" \

    http_status_code=$(
    curl -sL \
        --write-out "%{http_code}" \
        --output "$file_path" \
        "$url"
    )

    if [[ $http_status_code -ge 400 ]]; then
        echo "Failed to download $file: $http_status_code" >&2
        exit 2
    fi
    if [[ $http_status_code = 304 ]]; then
        continue
    fi

    echo "Importing $file"
    import_zip "$file_path" "$new_timestamp"
    mv "$file_path".metadata.new "$file_path".metadata
done \
< sorted_archive_urls.list
