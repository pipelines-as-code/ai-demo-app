# Agent Instructions

## Security Policy

This application must only use approved container base images from:

- `registry.access.redhat.com/*`
- `registry.redhat.io/*`
- `quay.io/*`

If a pipeline fails due to an image policy violation, the fix MUST replace the
unapproved base image with an equivalent approved UBI image. Do not suppress or
skip the security check.

### Approved Image Mapping

| Unapproved Image | Approved Replacement |
|---|---|
| `docker.io/library/alpine` | `registry.redhat.io/ubi9/ubi-minimal` |
| `docker.io/library/golang` | `registry.redhat.io/ubi9/go-toolset` |
| `docker.io/library/node` | `registry.redhat.io/ubi9/nodejs-20` |
| `docker.io/library/python` | `registry.redhat.io/ubi9/python-312` |
| `docker.io/library/openjdk` | `registry.access.redhat.com/ubi8/openjdk-11:1.11` |

## Security Notifications

If any changes affect the Dockerfile, container image references, or files in
the `security/` directory, notify the production security team via the #prodsec
Slack channel.

Include: which files changed, what was changed, and a link to the pull request.
