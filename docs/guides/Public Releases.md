# Public Releases

Wheatley uses two repositories with deliberately different histories:

- `private/main` is the canonical development history and receives ordinary,
  frequent commits;
- `public/main` contains one curated snapshot commit per public release.

The local `main` branch tracks `private/main`. The local `public-snapshot`
branch is an independent release branch whose commits never have private
development commits as ancestors. Never merge `main` into `public-snapshot`,
and never use `git push --all` or `git push --mirror` with the public remote.

## Publish a snapshot

Commit and push the intended release state to `private/main`, then run:

```bash
scripts/public-release.sh
```

The default is a dry run. It requires a clean checkout exactly matching
`private/main`, checks shell and JSON syntax, scans for private paths and
credential-shaped values, builds the browser client, runs D unit tests, builds
the console, creates a local `public` snapshot commit, and shows its diff.

After reviewing the local `public-snapshot` branch, publish it explicitly:

```bash
scripts/public-release.sh --push --message "Public snapshot YYYY-MM"
```

`--replace-history` exists only for establishing a new sanitized public root.
It force-pushes with an exact lease against the public tip observed by the
script. Normal monthly releases must not use it.

## Safety boundary

The snapshot commit reuses the exact tree from `private/main` but names only the
previous public snapshot as its parent. This exposes the selected files without
publishing private commit ancestry, messages, or intermediate file states.

Before changing repository visibility or publishing a new class of files,
also inspect GitHub branches, tags, releases, Actions logs, artifacts, issues,
and pull requests. The script protects Git objects pushed through `public/main`;
it cannot audit unrelated GitHub metadata.
