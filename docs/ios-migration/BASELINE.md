# Baseline

Recorded before native implementation. Repository-relative paths only; local checkouts are described by
placeholder.

| Item | Value |
| --- | --- |
| Origin | `https://github.com/Rift7/opencode-ios.git` |
| Upstream project | `https://github.com/anomalyco/opencode-android.git` (the fork's contents are the Android app) |
| Default branch | `dev` |
| Audited `dev` commit | `7358160e808fb1870eeb20f5da8df832667019d1` |
| Commit subject | `chore(deps): update Compose to 1.13 (#265)` |
| Audit time | 2026-11-21T18:28:04Z (see `audit/AUDIT.md`) |
| Baseline refresh | 2026-11-21T19:19:01Z — `origin/dev` still `7358160e…`, no intervening changes |
| Integration branch | `ios` |
| Task branch | `ios-foundation` |
| Worktree | `<migration-worktree>` (separate from the Android checkout at `<repository-root>`) |

## Branch creation evidence

`ios` was created directly from the audited commit. Its first commit is the migration documentation, whose
parent is the audited commit, so the branch has no preliminary merges:

```
$ git rev-parse --verify refs/heads/ios
5fa3093b3c7f04afc82b2b51e3ef4114feb68036

$ git log -1 --format='%H%n%P' refs/heads/ios
5fa3093b3c7f04afc82b2b51e3ef4114feb68036
7358160e808fb1870eeb20f5da8df832667019d1

$ git rev-list --count 7358160e808fb1870eeb20f5da8df832667019d1..refs/heads/ios
1

$ git merge-base --is-ancestor 7358160e808fb1870eeb20f5da8df832667019d1 refs/heads/ios && echo ok
ok
```

The audited commit was verified as the branch point **before** the first commit was made. No existing branch
was reset or overwritten: `ios` did not exist at audit time, and `ios-foundation` was created from `ios`
afterwards.

## Remote state at branch creation

```
$ git ls-remote --heads origin dev refs/heads/ios
7358160e808fb1870eeb20f5da8df832667019d1	refs/heads/dev
5fa3093b3c7f04afc82b2b51e3ef4114feb68036	refs/heads/ios
```

## What this baseline means

- Behaviour baseline: the Android app at `7358160e`. Current `dev` behaviour wins over October evidence.
- iOS evidence baseline: parity corpus synced at iOS `01eef583`; reference captures at iOS `d809b1e` and
  `16b40f7` (October). These are descriptions, not recoverable source.
- Native baseline: `ios` at `5fa3093b` (documentation only) plus the `ios-foundation` skeleton.

If `origin/dev` advances, audit the intervening delta before rebasing or merging it into `ios`; do not
assume the recorded SHA is still current.

## Phase 4 branch creation

`ios-networking` was created from `origin/ios` after fetching, not from the previous task branch and not
from `143d8f86`:

```
$ git fetch origin --prune
   143d8f86..d0fdf2f5  ios -> origin/ios

$ git merge-base --is-ancestor d0fdf2f5cc3c37b0e0fab6146a49469f0ff86540 origin/ios && echo ok
ok

$ git switch -c ios-networking origin/ios
$ git log -1 --oneline
d0fdf2f5 ios: complete the native core foundation (#2)
```

The merged tree was then checked for the completed foundation before any file was added: `ios/` exists with
`OpenCodeKit/Sources/{OpenCodeCore,OpenCodeServer,OpenCodeApp,OpenCodeTestSupport}`, and the package test
suite passed from that checkout. `origin/dev` was still the audited `7358160e`, so `dev`-derived behaviour in
Phase 4 was read at the audited commit.
