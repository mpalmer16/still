# Personal repository publishing procedure

This source-only snapshot starts a fresh history. The original local repository
remains the archival reference. Its Git objects and machine-specific work diary
are not part of this repository. No writing collection is supplied.

## Confirmed identity and destination

The user has verified these values for preparation:

- Author: Michael Palmer
- Email: mpalmer1661@gmail.com
- GitHub owner: mpalmer16, an individual account
- Proposed repository: mpalmer16/still
- Visibility: private

Author settings are repository-local. Do not modify global Git identity or the
archival repository. Connected accounts may differ from this personal owner.

**Stop before remote creation, adding a remote, or pushing until the user
approves the final reviewed commit.** The following remote steps are a manual
procedure for after that approval, not authorization to perform them now.

## 1. Review the sanitized source

In this publishing snapshot:

```sh
git status --short --branch
git log --format=fuller --all
git ls-files
git show --stat HEAD
git show HEAD
git remote -v
git config --local --get user.name
git config --local --get user.email
git config --local --get user.useConfigOnly
```

Expect one initial commit on `main`, a clean tree, no remote, and the identity
above. Review the committed tree for writing, credentials, absolute home paths,
databases, imported documents, exports, backups, session keys, logs, dependency
caches, and application bundles. Publish the committed source, not an archive of
the whole working directory. Never force-add ignored collection data.

Validation uses only fabricated text and disposable collections:

```sh
mix precommit
mix assets.build
python3 -m unittest discover -s scripts -p 'test_*.py'
```

See `native/NOTES.md` for packaging and native checks. Verification bundles must
use a separate identity and disposable data; never replace an existing app.

## 2. Confirm personal authentication

After publication approval, authenticate the personal account if needed:

```sh
gh auth login --hostname github.com --git-protocol https --web
# Or switch an already authenticated personal account:
# gh auth switch --hostname github.com --user mpalmer16
```

Stop if any check fails:

```sh
test "$(gh api user --jq .login)" = mpalmer16
test "$(gh api user --jq .type)" = User
test "$(git config --local --get user.name)" = 'Michael Palmer'
test "$(git config --local --get user.email)" = mpalmer1661@gmail.com
test "$(git config --local --get user.useConfigOnly)" = true
```

If an environment token overrides CLI authentication, resolve that discrepancy
before proceeding. Do not print tokens. Confirm `HEAD` equals the SHA approved
by the user. No work account or organization is an acceptable substitute.

## 3. Verify the user-created repository

The user reports creating `https://github.com/mpalmer16/still`. Do not create it
again. Its visibility and contents must still be verified through the personal
account before publication. The current work-connected integration cannot read
it, so a 404 is not proof of absence or privacy.

For a future fresh setup only, creation would be `gh repo create mpalmer16/still
--private` after explicit approval, or manual creation on GitHub: owner `mpalmer16`, name `still`,
**Private**, without initializing a README, license, or `.gitignore`. If the name
already exists, stop and inspect it; do not overwrite or change owners.

Before adding a remote, verify:

```sh
gh api repos/mpalmer16/still --jq '{owner: .owner.login, owner_type: .owner.type, visibility: .visibility, private: .private}'
```

Expect owner `mpalmer16`, owner type `User`, visibility `private`, and `private:
true`. The repository must be empty. Check `gh api repos/mpalmer16/still/branches`
returns an empty array. A nonempty repository requires review before any push.

## 4. Add the remote in this snapshot only

```sh
test -z "$(git remote)"
git remote add origin https://github.com/mpalmer16/still.git
git remote -v
```

Both URLs must identify exactly `mpalmer16/still`. Never run these commands in
the original archival repository. Preparation leaves all remotes absent.

## 5. Push the approved initial commit

Repeat the personal authentication and private repository checks. Confirm the
approved SHA, then push only `main`. Select the CLI credential helper for this
command without changing global Git configuration:

```sh
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push --set-upstream origin main
```

Do not push archived branches or tags. Do not force-push.

## 6. Verify ownership, visibility, and contents

```sh
gh api repos/mpalmer16/still --jq '{owner: .owner.login, owner_type: .owner.type, visibility: .visibility, private: .private}'
test "$(gh api repos/mpalmer16/still/commits/main --jq .sha)" = "$(git rev-parse HEAD)"
gh api 'repos/mpalmer16/still/git/trees/main?recursive=1' --jq '.tree[] | select(.type == "blob") | .path'
git ls-tree -r --name-only HEAD
git status --short --branch
```

Compare the remote and local file lists. Inspect the repository in GitHub and
confirm no private data or generated output is present. The matching commit SHA
verifies the published tree and initial history match the reviewed local commit.

## Scope and portability limits

Still still uses a live SQLite database. Keep it outside synchronization folders.
This preparation includes no storage redesign, cloud integration, hosted service,
or broader application cleanup.

The importer requires explicit `--source` rather than assuming a Documents path;
its document extraction rules remain the same. Existing notebook provenance keys
and placement rules remain for compatibility. They contain no writing text or
personal identity; all published fixtures using them are fabricated.

Mac bundles target the build machine's architecture and OS. Local ad-hoc signing
is not notarized distribution. Backend smoke checks do not establish physical
window, fullscreen, folder-picker, or WebKit typing behavior.

## Security maintenance included in this snapshot

Validation identified advisories in the original locked dependencies. This
snapshot raises the Bandit requirement to `~> 1.13.0` and locks Bandit 1.13.1,
Decimal 3.2.0, Thousand Island 1.6.0 (required by Bandit), and Plug Crypto 2.2.1.
The remainder of the dependency lock is unchanged. No writing schema, context,
LiveView, interface asset, native application, or startup configuration changed.

The upstream fixes address Bandit's
[blocked HTTP/2 send deadlines](https://github.com/mtrudel/bandit/security/advisories/GHSA-69m6-wcv4-rwcf),
[malformed request authority validation](https://github.com/mtrudel/bandit/security/advisories/GHSA-v53v-9hvg-37jf),
and Decimal's
[unbounded rounding allocation](https://github.com/ericmj/decimal/security/advisories/GHSA-6c27-994x-c52f).
The patched application is revalidated with the complete test suite and native
and Docker builds. The local Docker check also rejects malformed authority and
verifies the nonlocal Host guard after accounting for the existing production
SSL redirect. This targeted refresh is not a general dependency
upgrade or a claim that every possible security issue has been excluded.
