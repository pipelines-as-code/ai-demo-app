# Agent Instructions

## Security Policy

This application must only use approved container base images from:

- `registry.access.redhat.com/*`
- `registry.redhat.io/*`
- `quay.io/*`

If a pipeline fails due to an image policy violation, the fix MUST replace the
unapproved base image with an equivalent approved UBI image. Do not suppress or
skip the security check.

## Enforcement

Base image compliance is enforced at two points:

1. **Build time** -- The `verify-approved-base-images` pipeline task checks
   that all base images in `BASE_IMAGES_DIGESTS` (produced by buildah) match
   an approved prefix from `ALLOWED_IMAGES.yaml`. If verification fails, the
   `gate-decision` task blocks the pipeline. Critical CVEs detected by the
   RHACS image scan also block the pipeline via `gate-decision`.
2. **Deploy time** -- RHACS admission controller policy blocks pods using
   images without the `vendor=Red Hat, Inc.` label (defense in depth).

### Approved Image Mapping

The mapping table below defines the approved replacement image family for each
unapproved base image. When the SRE agent fixes a Dockerfile automatically, it
should use the mapped family as the compatibility anchor, then search official
Red Hat image sources for the correct compatible approved image reference and
pin it to an explicit digest.

Never use a floating `latest` tag for these replacements. The final `FROM`
image must be pinned with `@sha256:...`.

If a compatible digest-pinned replacement cannot be determined confidently from
official Red Hat sources, the agent must fall back to the exact replacement
family listed in this table and continue until it can pin the image correctly.

| Unapproved Image | Approved Replacement |
|---|---|
| `docker.io/library/alpine` | `registry.redhat.io/ubi9/ubi-minimal` |
| `docker.io/library/golang` | `registry.redhat.io/ubi9/go-toolset` |
| `docker.io/library/node` | `registry.redhat.io/ubi9/nodejs-20` |
| `docker.io/library/python` | `registry.redhat.io/ubi9/python-312` |
| `docker.io/library/eclipse-temurin` | `registry.access.redhat.com/ubi8/openjdk-11:1.11` |

## Security Notifications

If any changes affect the Dockerfile, container image references, files in
the `security/` directory, or Tekton pipeline definitions in `.tekton/`,
notify the team via the configured Slack webhook.

Include: which files changed, what was changed, and a link to the pull request.
