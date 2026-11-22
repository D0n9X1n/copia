#!/usr/bin/env bash
# Fast-forward the wiki's source watermark, including when a newer SHA has identical pages.
set -euo pipefail
export LC_ALL=C
[[ $# == 3 ]] || { echo 'usage: publish-wiki.sh SOURCE_DIR WIKI_CLONE SOURCE_SHA' >&2; exit 2; }
source_dir=$1; wiki_repo=$2; sha=$3
source_git() { git -C "$source_dir" "$@"; }
wiki_git() { git -C "$wiki_repo" "$@"; }
[[ $sha =~ ^[0-9a-f]{40}$ && $(source_git rev-parse HEAD) == "$sha" ]] || { echo 'wiki source is not the event SHA' >&2; exit 1; }
# Only the dedicated temporary clone may be switched when reconciling a competing push.
status=$(wiki_git status --porcelain)
[[ -z $status ]] || { echo 'dirty wiki worktree' >&2; exit 1; }
shopt -s nullglob
pages=("$source_dir"/*.md)
(( ${#pages[@]} > 0 )) || { echo 'no wiki pages' >&2; exit 1; }

rejected_base=
while :; do
    wiki_git fetch --no-tags origin refs/heads/master
    base=$(wiki_git rev-parse FETCH_HEAD)
    if [[ -n $rejected_base ]]; then
        [[ $base != "$rejected_base" ]] || { echo 'wiki push failed without a new remote tip' >&2; exit 1; }
        wiki_git merge-base --is-ancestor "$rejected_base" "$base"
    fi
    # Existing mirrors record the exact source in the commit subject. Follow first parents
    # so an unrelated wiki edit doesn't erase that watermark. An initial wiki has none.
    subject=$(wiki_git log -1 --first-parent --grep='^Publish wiki from ' --format=%s "$base")
    if [[ -n $subject ]]; then
        [[ $subject =~ ^Publish\ wiki\ from\ ([0-9a-f]{40})$ ]] || { echo 'invalid wiki source watermark' >&2; exit 1; }
        previous=${BASH_REMATCH[1]}
        # A checkout for an older event need not yet contain the winning source commit.
        source_git fetch --no-tags origin refs/heads/main
        main=$(source_git rev-parse FETCH_HEAD)
        source_git merge-base --is-ancestor "$previous" "$main"
        source_git merge-base --is-ancestor "$sha" "$main"
        if source_git merge-base --is-ancestor "$sha" "$previous"; then
            echo "Wiki already mirrored $previous; no publish needed for validated $sha."
            exit 0
        fi
        source_git merge-base --is-ancestor "$previous" "$sha"
    fi

    wiki_git checkout -q --detach "$base"
    find "$wiki_repo" -maxdepth 1 -type f -name '*.md' -delete
    cp -- "${pages[@]}" "$wiki_repo/"
    wiki_git add --all
    wiki_git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -q --allow-empty -m "Publish wiki from $sha"
    if result=$(wiki_git push --porcelain origin HEAD:refs/heads/master 2>&1); then
        echo "Published wiki from $sha."; exit 0
    fi
    # A transport/auth/hook failure is not a race, even if the tip also changed.
    # Git's porcelain rejection identifies a non-fast-forward before we fetch again.
    case "$result" in
        *$'!\tHEAD:refs/heads/master\t[rejected] (fetch first)'*|*$'!\tHEAD:refs/heads/master\t[rejected] (non-fast-forward)'*) ;;
        *$'!\tHEAD:refs/heads/master\t[remote rejected] (incorrect old value provided)'*) ;;
        *$'!\tHEAD:refs/heads/master\t[remote rejected] (failed to update ref)'*)
            # Older servers give only a generic rejection; require the explicit CAS mismatch too.
            mismatch="cannot lock ref 'refs/heads/master': is at [0-9a-f]{40} but expected $base"
            [[ $result =~ $mismatch ]] || { printf '%s\n' "$result" >&2; exit 1; } ;;
        *) printf '%s\n' "$result" >&2; exit 1 ;;
    esac
    rejected_base=$base
    echo 'Wiki advanced during publish; reconciling against its new tip.' >&2
done
