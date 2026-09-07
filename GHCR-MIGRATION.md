# Migrating the private registry to GHCR

Moving `ballroom-competition-web` and `ballroom-syllabi` off the self-hosted Zot
registry onto `ghcr.io`.

## Why

A registry that spins down cannot be a CI push target — GitHub Actions runs when
you merge, not when the box happens to be up. So the registry CI pushes to has to
be always-on, which meant Zot in production could never be part of an environment
that spins down. GHCR is always available and needs no self-hosting.

## The pull secret covers both registries

The `.dockerconfigjson` in the vault holds auths for **both**
`zot.zachsexton.com` and `ghcr.io`:

```json
{"auths":{"zot.zachsexton.com":{"auth":"..."},"ghcr.io":{"auth":"..."}}}
```

A Docker config can carry many registries, so the same secret authenticates
before and after the manifest flip. That removes the ordering constraint on the
credential entirely — it can be rolled out first, and nothing breaks whichever
registry the manifests currently name.

What remains ordered is only the *image*: it has to exist in GHCR before the
manifest points at it.

## The ordering trap

`k8s/apps/base/` is shared by production and staging, and production's Argo CD
self-heals from `master`. **The moment the image reference changes on `master`,
production tries to pull from the new registry.** So:

With the dual-registry secret above rolled out, the credential half of this is
solved. What is left is the image: **if it is not in GHCR yet, production gets
`ImagePullBackOff`.** The manifest change must land after the images exist.

There is no way to stage this per-environment: the image reference lives in the
shared base, so both environments cut over together.

## Order of operations

### 1. Push images to GHCR first

Push and merge the `ghcr-migration` branch in the app repos. **Pushing these
needs a token with the `workflow` scope** — neither the `gh` OAuth token nor the
classic PAT in 1Password has it, so this cannot be done from an agent session:

```bash
gh auth refresh -s workflow      # then push
```


- `ztsexton/ballroom-competition-web` — `docker-push.yaml` and `update-deployment.yaml`
- `ztsexton/ballroom-study-buddy` — `build-and-push.yml`

> `update-deployment.yaml` rewrites the image line in this repo automatically
> once the build succeeds. Its replace matches **either** registry, so it is safe
> whichever one the manifest currently points at — but it means merging the app
> repo will move `master` here on its own. Do steps 2 and 3 first.

Confirm the packages exist before going further:

```bash
PAT=<classic PAT with read:packages>
BT=$(curl -sS -u ztsexton:$PAT \
  "https://ghcr.io/token?service=ghcr.io&scope=repository:ztsexton/ballroom-competition-web:pull" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $BT" \
  https://ghcr.io/v2/ztsexton/ballroom-competition-web/tags/list
```

`200` means the package is there and the credential can read it.

### 2. Add ghcr.io to the 1Password item

```bash
eval $(op signin)                                   # session must be in this shell
./scripts/onepassword-registry-auth.sh show         # read-only
./scripts/onepassword-registry-auth.sh add-ghcr
./scripts/onepassword-registry-auth.sh verify
```

`add-ghcr` reads the classic PAT from `Personal Infra PAT Github Classic`, merges
a `ghcr.io` entry into the existing `.dockerconfigjson` — preserving the Zot
entry byte-for-byte — and writes it back to both vaults, reading each one back
afterwards to confirm it landed. It refuses a fine-grained token, and never
prints the value.

No kubectl: the pull secret is a `OnePasswordItem`
(`k8s/apps/base/registry-credentials`), so the operator applies the change in
every cluster.

Because the value still authenticates to Zot, this is safe to run immediately and
in any order — each environment keeps pulling from whichever registry its
manifests name, and switches to GHCR when they change, with no second edit.

### 3. Nothing to do for staging

Same CR, same vault item — the operator syncs it there too.

### 4. Merge the manifest change here

Only once 1–3 are done. Then:

```bash
./scripts/staging.sh verify
curl -sI https://petfoodfinder.app | head -1     # production
```

## Afterwards

- Delete `ZOT_USERNAME` and `ZOT_PASSWORD` from both app repos' secrets
- Remove Zot from the staging overlay: it holds nothing, uses `emptyDir`, and
  only ever served an empty catalog. Production's Zot can stay until its images
  are no longer referenced anywhere
- Rotate the Zot admin password — it was pasted into a chat transcript during
  this work

## Notes

**The pull credential must be a classic PAT.** Fine-grained tokens are documented
as unsupported for GHCR pulls. Verified: a classic `ghp_` token exchanges for a
bearer token that returns `200` on `/v2/`, where anonymous access returns
`DENIED`.

**`ghcr.io/v2/` returns 401 to basic auth even with valid credentials** — it uses
bearer-token auth, so the token exchange is the only meaningful test.

**`ballroom-syllabi` has never been in any registry.** The Zot catalog contained
only `ballroom-competition-web`, which is why its deployment is pinned to a tag
that does not exist and `syllabus.zachsexton.com` returns 404 in production
today. Migrating it to GHCR is what will finally publish it.
