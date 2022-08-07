#! /usr/bin/env bash
set -Eeuo pipefail

base=https://data.finlex.fi
cat > archives-xml.list <<EOF
https://data.finlex.fi/download/xml/asd/asd-fi.zip
https://data.finlex.fi/download/xml/asd/asd-sv.zip
https://data.finlex.fi/download/xml/kho/kho-fi.zip
https://data.finlex.fi/download/xml/kho/kko-sv.zip
https://data.finlex.fi/download/xml/kko/kko-fi.zip
https://data.finlex.fi/download/xml/kko/kko-sv.zip
EOF

cat > archives-jsonld.list <<EOF
https://data.finlex.fi/download/rdf/sd-jsonld-fi.zip
https://data.finlex.fi/download/rdf/kko-jsonld-fi.zip
https://data.finlex.fi/download/rdf/kho-jsonld-fi.zip
EOF

cat > archives-nq.list <<EOF
https://data.finlex.fi/download/rdf/ajantasa-nq.zip
https://data.finlex.fi/download/rdf/kko-nq.zip
https://data.finlex.fi/download/rdf/kho-nq.zip
https://data.finlex.fi/download/rdf/alkup-nq.zip
EOF


import_zip() {
    if [[ $# != 3 ]]; then
        echo "Usage: import_zip zipfile(filename) update_timestamp archive_type" >&2
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
    # NB3. stat -c %W is not available for Linux (always 0) so we're also using %Y
    newest_ctime=$(set +o pipefail; find "$dir" -type f -exec stat -c %W/%Y {} + | tr / '\n' | sort -rn | head -n1)
    timestamp=$(TZ=Europe/Helsinki date -R -d "@${newest_ctime}")

    if [[ $archive_type = xml ]]; then
        output=data
        # asd-fi.zip -> data/asd/fi
        dest_dir=$output/$(basename "$zipfile" .zip | sed 's#-#/#')
        output=$(readlink -f "$output")
    else
        output=data/$(basename "$zipfile" .zip)
        dest_dir=$output
    fi
    rsync -a "$dir"/ "$output"/
    git add "$dest_dir"

    GIT_COMMITTER_DATE=$timestamp \
    GIT_AUTHOR_DATE=$timestamp \
    git commit -m "Import $(basename "$zipfile") as of $update_timestamp" || true # skip making empty commits

    # Micro-optimization: Save disk space by keeping the working directory empty
    rm -rf "$dest_dir"
    cleanup
}

mkdir -p data/
mkdir -p archives/
touch archives/.dummy

# NB: disabled nq/nquads since there are files >100MB in there.
# 100MB/file is the maximum limit for Github.
#for archive_type in xml jsonld nq; do
for archive_type in xml jsonld; do
cat archives-"$archive_type".list |
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

    # We could get HTTP 503 Backend fetch failed. In that case, ignore metadata processing and try to download the file anyway.
    if curl -fsI "$url" |
        grep -iE '^(ETag|Last-Modified): ' \
        > "$file_path".metadata.new
    then
        new_etag=$(grep -i ^ETag: "$file_path".metadata.new | sed 's/^ETag: //i')
        new_timestamp=$(grep -i ^Last-Modified: "$file_path".metadata.new | sed 's/^Last-Modified: //i')
        if [[ $new_etag = "$etag" ]] && [[ $new_timestamp = "$timestamp" ]]; then
            echo "File has not changed from server: $file -- Skipping."
            rm "$file_path".metadata.new
            continue
        fi
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
        continue
    fi
    if [[ $http_status_code = 304 ]]; then
        continue
    fi

    echo "Importing $file"
    import_zip "$file_path" "$new_timestamp" "$archive_type"
    mv "$file_path".metadata.new "$file_path".metadata
done # /url
done # /archive_type
