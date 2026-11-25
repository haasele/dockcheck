# Tag-bump addon for dockcheck - sourced by dockcheck.sh when -T N is used.
#
# Finds newer *versioned* tags (e.g. 01.00.10.00 -> 01.00.11.00) for containers whose
# compose file pins a fixed tag, and lets dockcheck rewrite the tag before pulling.
# Plain digest checks (latest / rolling tags) are still done by dockcheck itself.
#
# Requires: regctl (already a dockcheck dependency), sort -V, jq, and read access to the
# compose files (when dockcheck runs containerized, mount them at the same path).

# Debug output (stderr) when TagBumpDebug=true, to see why a container got no bump.
tagbump_dbg() { [[ "${TagBumpDebug:-false}" == true ]] && printf 'tagbump[%s]: %s\n' "$1" "$2" >&2; return 0; }

# Split a tag into prefix|version|suffix. Returns 1 when the tag contains no number.
tagbump_split() {
  local re='^([^0-9]*)([0-9]+([._-][0-9]+)*)(.*)$'
  [[ "$1" =~ $re ]] || return 1
  printf '%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
}

# Escape a string for use in a (POSIX ERE) regex / sed pattern.
tagbump_esc() { sed -e 's/[][\.^$*+?(){}|\/]/\\&/g' <<< "$1"; }

# tagbump_next_tag <current-tag> <lock-segments>   (candidate tags on stdin, one per line)
# Prints the highest tag that has the same format as <current-tag> and is greater than it.
# The first <lock-segments> numeric segments must stay unchanged (0 = anything newer).
# Prefix and suffix (e.g. "v", "-alpine") must match exactly, so rc/sha/other-variant tags are ignored.
tagbump_next_tag() {
  local cur="$1" lock="${2:-0}" parts prefix ver suffix shape lockpfx rx best t tparts tver
  parts=$(tagbump_split "$cur") || return 1
  IFS='|' read -r prefix ver suffix <<< "$parts"

  shape=$(sed -E 's/[0-9]+/[0-9]+/g; s/\./\\./g' <<< "$ver")
  rx="^$(tagbump_esc "$prefix")${shape}$(tagbump_esc "$suffix")\$"

  lockpfx=""
  if (( lock > 0 )); then
    lockpfx=$(awk -v n="$lock" '{
      out=""; rest=$0
      for (i=1;i<=n;i++) {
        if (!match(rest,/^[0-9]+/)) break
        out=out substr(rest,1,RLENGTH); rest=substr(rest,RLENGTH+1)
        if (i<n) { out=out substr(rest,1,1); rest=substr(rest,2) }
      }
      print out }' <<< "$ver")
  fi

  best="$ver"
  while IFS= read -r t; do
    [[ "$t" =~ $rx ]] || continue
    tparts=$(tagbump_split "$t") || continue
    tver=${tparts#*|}; tver=${tver%|*}
    if [[ -n "$lockpfx" ]]; then
      # Compare whole segments only (lock "1.0" must not match "1.01")
      [[ "$tver" == "$lockpfx" || "$tver" == "$lockpfx"[._-]* ]] || continue
    fi
    if [[ "$tver" != "$best" && "$(printf '%s\n%s\n' "$best" "$tver" | sort -V | tail -n1)" == "$tver" ]]; then
      best="$tver"
    fi
  done
  [[ "$best" == "$ver" ]] && return 1
  printf '%s%s%s\n' "$prefix" "$best" "$suffix"
}

# tagbump_compose_files <container-labels-json>
# Prints the compose files of a container, resolved against its working dir.
tagbump_compose_files() {
  local labels="$1" wd cfgs conf
  wd=$("$jqbin" -r '."com.docker.compose.project.working_dir" // empty' <<< "$labels")
  cfgs=$("$jqbin" -r '."com.docker.compose.project.config_files" // empty' <<< "$labels")
  [[ -z "$cfgs" ]] && return 1
  for conf in ${cfgs//,/ }; do
    if [[ "$conf" == /* ]]; then printf '%s\n' "$conf"; else printf '%s/%s\n' "$wd" "$conf"; fi
  done
}

# tagbump_check <container> <image-ref> <container-labels-json>
# Returns 0 and stores "<repo>|<old>|<new>|<files>" in $TagBumpDir/<container> if a newer tag
# exists AND the old "image: repo:tag" literal was found in a readable compose file.
tagbump_check() {
  local name="$1" image="$2" labels="$3" repo cur lock new files f hits=()
  [[ "$image" == *@sha256:* ]] && { tagbump_dbg "$name" "pinned by digest, skipped"; return 1; }
  cur="${image##*:}"
  [[ "$image" != *:* || "$cur" == */* ]] && { tagbump_dbg "$name" "no tag in image ref, skipped"; return 1; }
  [[ "$cur" == "latest" ]] && { tagbump_dbg "$name" "tag is latest, digest check only"; return 1; }
  repo="${image%:*}"
  tagbump_split "$cur" > /dev/null || { tagbump_dbg "$name" "tag '$cur' has no version number, skipped"; return 1; }

  lock=$("$jqbin" -r '."mag37.dockcheck.tag-lock" // empty' <<< "$labels")
  [[ "$lock" =~ ^[0-9]+$ ]] || lock="${TagBumpLock:-0}"

  local taglist
  taglist=$($t_out "$regbin" -v error tag ls "$repo" 2>&1) || { tagbump_dbg "$name" "regctl tag ls $repo failed: ${taglist:0:200}"; return 1; }
  new=$(tagbump_next_tag "$cur" "$lock" <<< "$taglist") || {
    tagbump_dbg "$name" "$repo:$cur is already the newest matching tag (lock=$lock, $(wc -l <<< "$taglist") tags listed)"
    return 1; }

  files=$(tagbump_compose_files "$labels") || { tagbump_dbg "$name" "no compose files in container labels"; return 1; }
  while IFS= read -r f; do
    if [[ ! -r "$f" ]]; then
      tagbump_dbg "$name" "compose file not readable by $(id -un): $f"
    elif grep -Eq "image:[[:space:]]*[\"']?$(tagbump_esc "$repo"):$(tagbump_esc "$cur")([\"'[:space:]]|\$)" "$f"; then
      hits+=("$f")
    else
      tagbump_dbg "$name" "no literal 'image: $repo:$cur' line in $f; image lines found: $(grep -E '^[[:space:]]*image:' "$f" | tr -s ' ' | tr '\n' ';')"
    fi
  done <<< "$files"
  [[ ${#hits[@]} -gt 0 ]] || {                           # literal not found (variables / not mounted) - leave alone
    tagbump_dbg "$name" "newer tag $new exists, but 'image: $repo:$cur' not found in: $(echo $files) (see lines above)"
    return 1; }

  printf '%s|%s|%s|%s\n' "$repo" "$cur" "$new" "$(IFS=,; echo "${hits[*]}")" > "$TagBumpDir/$name"
  return 0
}

# tagbump_rewrite <container> <from-tag> <to-tag>  - in-place tag swap in the stored compose files
tagbump_rewrite() {
  local name="$1" from="$2" to="$3" repo old new files f
  IFS='|' read -r repo old new files < "$TagBumpDir/$name"
  for f in ${files//,/ }; do
    sed -E -i "s@(image:[[:space:]]*[\"']?)$(tagbump_esc "$repo"):$(tagbump_esc "$from")([\"'[:space:]]|\$)@\1${repo}:${to}\2@" "$f" || return 1
  done
}

# tagbump_apply <container>
# Rewrites the tag in the compose file(s) and prints the new image ref.
# One backup copy per file and run is kept as <file>.dockcheck-bak.
tagbump_apply() {
  local name="$1" repo old new files f
  [[ -s "$TagBumpDir/$name" ]] || return 1
  IFS='|' read -r repo old new files < "$TagBumpDir/$name"
  for f in ${files//,/ }; do
    if [[ ! -e "$f.dockcheck-bak" || "$f.dockcheck-bak" -ot "$TagBumpDir" ]]; then
      cp -p "$f" "$f.dockcheck-bak" || return 1
    fi
  done
  tagbump_rewrite "$name" "$old" "$new" || { tagbump_rewrite "$name" "$new" "$old"; return 1; }
  printf '%s:%s\n' "$repo" "$new"
}

# tagbump_revert <container> - undo tagbump_apply (e.g. when pulling the new image failed)
tagbump_revert() {
  local name="$1" repo old new files
  [[ -s "$TagBumpDir/$name" ]] || return 1
  IFS='|' read -r repo old new files < "$TagBumpDir/$name"
  tagbump_rewrite "$name" "$new" "$old"
}

# tagbump_list - print a summary of all found bumps (for the CLI output)
tagbump_list() {
  local f name repo old new
  for f in "$TagBumpDir"/*; do
    [[ -s "$f" ]] || continue
    name=${f##*/}; IFS='|' read -r repo old new _ < "$f"
    printf '%s: %s -> %s\n' "$name" "$old" "$new"
  done
}

# tagbump_digest_info <container> - for same-tag updates: build date + digest, local vs. registry
tagbump_digest_info() {
  local name="$1" image imgid ldate rdate ldig rdig
  image=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null) || return 0
  imgid=$(docker inspect "$name" --format '{{.Image}}' 2>/dev/null)
  ldate=$(docker image inspect "$imgid" --format '{{.Created}}' 2>/dev/null | cut -c1-16)
  rdate=$($t_out "$regbin" -v error image inspect "$image" --format '{{.Created}}' 2>/dev/null | cut -c1-16)
  ldig=$(docker image inspect "$imgid" --format '{{.RepoDigests}}' 2>/dev/null | grep -o 'sha256:[0-9a-f]*' | head -1 | cut -c8-19)
  rdig=$($t_out "$regbin" -v error image digest "$image" 2>/dev/null | cut -c8-19)
  printf '%s: %s\n  running:  built %s, digest %s\n  registry: built %s, digest %s\n' \
    "$name" "$image" "${ldate:-?}" "${ldig:-?}" "${rdate:-?}" "${rdig:-?}"
}
