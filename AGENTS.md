# Agent Instructions

## Security Policy

This application must only use approved container base images from:

- `registry.access.io/*`
- `registry.access.redhat.io/*`
- `quay.io/*`

If a pipeline fails due to an image policy violation, the fix MUST replace the
unapproved base image with an equivalent approved UBI image. Do not suppress or
skip the security check.

### Approved Image Mapping

| Unapproved Image | Approved Replacement |
|---|---|
| `docker.io/library/alpine` | `registry.access.io/ubi9/ubi-minimal` |
| `docker.io/library/golang` | `registry.access.io/ubi9/go-toolset` |
| `docker.io/library/node` | `registry.access.io/ubi9/nodejs-20` |
| `docker.io/library/python` | `registry.access.io/ubi9/python-312` |

## Security Notifications

If any changes affect the Dockerfile, container image references, or files in
the `security/` directory, notify the production security team via the #prodsec
Slack channel.

Include: which files changed, what was changed, and a link to the pull request.
