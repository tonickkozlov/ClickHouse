## When copying Cloudflare build specifics make sure git history is not lost!

```sh
# example, didn't test this yet

OLD_BRANCH=cf/v20.8
FILES="cfsetup.yaml cf-build"

COMMITS=$(git log "origin/$OLD_BRANCH" --pretty=format:"%h" --reverse -- $FILES)
git format-patch --stdout $COMMITS -- $FILES | git am --committer-date-is-author-date -
```
