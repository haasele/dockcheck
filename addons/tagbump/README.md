## Tag bump addon

Dockcheck normally compares the registry digest of the *same* tag, which covers `latest` and rolling tags.
A container pinned to a versioned tag (`app:01.00.10.00`) is never offered `01.00.11.00`.
This addon closes that gap.

### Usage

```shell
dockcheck.sh -T 2          # also look for newer versioned tags, first 2 segments must stay equal
dockcheck.sh -n -T 0       # only list, any newer version (including major bumps)
dockcheck.sh -y -T 3 -d 3  # unattended, only last segment may change
```

Or in `dockcheck.config`: `TagBump=true` and `TagBumpLock=2`.

`N` (`-T N` / `TagBumpLock`) = number of leading version segments that must stay unchanged, `0` = any newer version.
For `01.00.10.00`: `3` -> `01.00.10.xx`, `2` -> `01.00.xx.xx`, `1` -> `01.xx.xx.xx`, `0` -> anything newer.
Per container override with the compose label `mag37.dockcheck.tag-lock: N`.

### How it works

1. Tag of the running image is split into `prefix` + numeric version + `suffix` (`v` `1.9.0` `-alpine`).
2. `regctl tag ls <repo>` lists the tags; only tags with the *same shape* (same prefix, same suffix, same number of segments) are candidates. `latest`, `sha-*`, `-rc1` and other variants are ignored.
3. Versions are compared numerically (`sort -V`), so `1.10` > `1.9`. Leading zeros are preserved.
4. If a newer tag exists, the container is reported as having an update.
5. On update the `image:` line is rewritten in the compose file(s) (backup: `<file>.dockcheck-bak`, one per run), then dockcheck pulls and recreates as usual. If the pull fails the change is reverted.

### Limitations

- Only literal `image: repo:tag` lines are rewritten. Images set through variables (`${IMAGE}`), `.env` files or YAML anchors are skipped, no bump is offered.
- The compose files must be readable by dockcheck at the path stored in the container labels. When running dockcheck containerized, mount the compose directories at the same path.
- Containers not started via compose (`docker run`) are not supported.
- `-d N` (minimum image age) does not apply to tag bumps.
- Bumping major versions can need migrations. Use `-T 1`/`-T 2`, or the label, for anything that is not safe to auto-update.
- `regctl tag ls` can be rate limited on some registries (Docker Hub), avoid very frequent runs.
