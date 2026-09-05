# Migrating the private registry to GHCR

Moving `ballroom-competition-web` and `ballroom-syllabi` off the self-hosted Zot
registry onto `ghcr.io`.

## Why

A registry that spins down cannot be a CI push target — GitHub Actions runs when
you merge, not when the box happens to be up. So the registry CI pushes to has to
be always-on, which meant Zot in production could never be part of an environment
that spins down. GHCR is always available and needs no self-hosting.

## The ordering trap

`k8s/apps/base/` is shared by production and staging, and production's Argo CD
self-heals from `master`. **The moment the image reference changes on `master`,
production tries to pull from the new registry.** So:

- if the image is not in GHCR yet → `ImagePullBackOff`
- if the pull secret still holds Zot credentials → `no basic auth credentials`

Either takes production down. The manifest change must land **last**.

There is no way to stage this per-environment: the image reference lives in the
shared base, so both environments cut over together.

## Order of operations

### 1. Push images to GHCR first

Merge the `ghcr-migration` branch in the app repos:

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

### 2. Give production a GHCR pull secret

Production is **not** bootstrapped by Terraform (`bootstrap_cluster = false`), so
nothing creates this for it. Its existing `zot-registry-credentials` secret holds
Zot credentials.

Keep the name and replace the contents — that avoids touching the
`imagePullSecrets` reference in the shared base manifest, which would otherwise
have to change for both environments at once:

```bash
# against the production cluster
kubectl -n web create secret generic zot-registry-credentials \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson='{"auths":{"ghcr.io":{"auth":"<base64 of ztsexton:ghp_...>"}}}' \
  --dry-run=client -o yaml | kubectl apply -f -
```

The secret keeps its Zot-era name until production is next rebuilt. Misleading,
but renaming it now would break production, since the rename would reach it
through the shared manifest before anything created the new name.

### 3. Staging already has it

`registry_dockerconfigjson` in `terraform/envs/staging/terraform.tfvars` is
already pointed at `ghcr.io`, and the bootstrap writes the secret on every
rebuild. Re-run to apply:

```bash
./scripts/staging.sh up
```

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
