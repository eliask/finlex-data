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
    if [[ $# != 1 ]]; then
        echo "import_zip(): invalid args" >&2
        exit 1
    fi
    zipfile=$1

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
    git commit --allow-empty -m "Import $(basename "$zipfile")"
}

if [[ -n $(git branch) ]]; then
    git log --reverse --format=tformat:%s \
        | grep '^Import ' \
        | sed 's/^Import //' \
        > imported_files.list
else
    true > imported_files.list
fi

mkdir -p data/

# files_not_found_in_server=$(comm -2 imported_files.list <(sed 's#.*/##' sorted_archive_urls.list))

mkdir -p archives/
touch archives/.dummy
grep -Fvf \
    <(cat imported_files.list <(ls -A archives/) | sed 's#^#/#') \
    sorted_archive_urls.list \
    > archives_to_download.list || true

if [[ -s imported_files.list ]]; then
    if ! grep -Fvf \
        <(< imported_files.list sed 's#^#/#') \
        sorted_archive_urls.list
    then
        echo "Nothing new to import"
        exit 0
    fi
else
    cat sorted_archive_urls.list
fi \
    > archives_to_import.list

{
    cd archives/
    [[ -s archives_to_download.list ]] && < archives_to_download.list xargs wget
    cd ..
}

< archives_to_download.list sed 's#.*/#archives/#' \
| while read -r file; do
    [[ -f $file ]]
    import_zip "$file"
done

sed 's#.*/#archives/#' archives_to_import.list | while read -r file; do
    echo "Importing $file"
    import_zip "$file"
done
