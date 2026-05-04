#!/usr/bin/env bash
# Check if the current branch's PR touches policy-relevant files and send a Slack alert.
set -euo pipefail

unique_lines() {
  awk 'NF && !seen[$0]++'
}

count_lines() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    echo 0
    return
  fi

  printf '%s\n' "${value}" | sed '/^$/d' | wc -l | tr -d ' '
}

append_line() {
  local var_name="$1"
  local line="$2"

  if [[ -z "${line}" ]]; then
    return
  fi

  printf -v "${var_name}" '%s%s\n' "${!var_name:-}" "${line}"
}

truncate_text() {
  local value="$1"
  local max_length="$2"

  if (( ${#value} <= max_length )); then
    printf '%s' "${value}"
    return
  fi

  printf '%s...' "${value:0:max_length-3}"
}

normalize_pr_title() {
  local pr_number="$1"
  local title="$2"

  title=$(printf '%s' "${title}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ -z "${title}" ]]; then
    return
  fi

  printf '%s' "${title}" | sed -E "s/^[Pp][Rr][[:space:]]*#?[[:space:]]*${pr_number}([[:space:]]*[:.-][[:space:]]*|[[:space:]]+)?//"
}

format_section_body() {
  local value="$1"
  printf '%s\n' "${value}" | sed '/^$/d' | sed 's/^/    /'
}

line_in_list() {
  local needle="$1"
  local haystack="$2"

  if [[ -z "${needle}" || -z "${haystack}" ]]; then
    return 1
  fi

  printf '%s\n' "${haystack}" | grep -Fxq "${needle}"
}

# Only run from the PAC AI CI analysis context.
if [[ "${PAC_LLM_EXECUTION_CONTEXT:-}" != "ci" ]]; then
  echo "Not running in PAC CI analysis context — skipped."
  exit 0
fi

SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
AI_SUMMARY="${PAC_CHANGE_SUMMARY:-}"
PR_NUMBER="${PAC_PR_NUMBER:-0}"
PR_URL="${PAC_REPO_URL:-}"
if [[ -n "${PR_URL}" && "${PR_NUMBER}" != "0" ]]; then
  PR_URL="${PR_URL%/}/pull/${PR_NUMBER}"
fi

if [[ "${PR_NUMBER}" == "0" ]]; then
  echo "No pull request metadata available — skipped."
  exit 0
fi

CHANGED_FILES=""
if [[ -n "${PAC_CHANGED_FILES_B64:-}" ]]; then
  CHANGED_FILES=$(printf '%s' "${PAC_CHANGED_FILES_B64}" | base64 -d 2>/dev/null || true)
fi

PR_FILES_JSON=""
if [[ -n "${PAC_REPO_OWNER:-}" && -n "${PAC_REPO_NAME:-}" ]] && command -v gh >/dev/null 2>&1; then
  PR_FILES_JSON=$(gh api \
    "repos/${PAC_REPO_OWNER}/${PAC_REPO_NAME}/pulls/${PR_NUMBER}/files" \
    --paginate 2>/dev/null || true)
fi

if [[ -z "${CHANGED_FILES}" && -n "${PR_FILES_JSON}" ]]; then
  CHANGED_FILES=$(printf '%s' "${PR_FILES_JSON}" | jq -r '.[].filename' 2>/dev/null || true)
fi

if [[ -z "${CHANGED_FILES}" && -z "${PR_FILES_JSON}" ]]; then
  echo "No changed-file metadata available for PR #${PR_NUMBER} — skipped."
  exit 0
fi

PATH_NOTIFY_FILES=$(printf '%s\n' "${CHANGED_FILES}" | sed '/^$/d' | grep -E '^(\.tekton/|Dockerfile|security/)' || true)

IMAGE_MATCHES=""
IMAGE_FILES=""
if [[ -n "${PR_FILES_JSON}" ]]; then
  IMAGE_MATCHES=$(printf '%s' "${PR_FILES_JSON}" | jq -r '
    def changed_lines:
      (.patch // "")
      | split("\n")
      | map(select(
          ((startswith("+") or startswith("-")))
          and (startswith("+++") | not)
          and (startswith("---") | not)
        ));
    def image_like:
      .[1:] | test("(^|[[:space:][:punct:]])(FROM[[:space:]]+\\S+|image[[:space:]]*:[[:space:]]*\\S+|containerImage[[:space:]]*[:=][[:space:]]*\\S+|[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/[^[:space:]]+(?::[^[:space:]]+)?(?:@sha256:[a-f0-9]{64})?)"; "i");
    .[]
    | .filename as $filename
    | [changed_lines[] | select(image_like)][0:2][]
    | [$filename, .] | @tsv
  ' 2>/dev/null || true)
  if [[ -n "${IMAGE_MATCHES}" ]]; then
    IMAGE_FILES=$(printf '%s\n' "${IMAGE_MATCHES}" | cut -f1 | unique_lines)
  fi
fi

TEKTON_FILES=$(printf '%s\n' "${PATH_NOTIFY_FILES}" | grep '^\.tekton/' || true)
SECURITY_FILES=$(printf '%s\n' "${PATH_NOTIFY_FILES}" | grep '^security/' || true)
DOCKER_FILES=$(printf '%s\n' "${PATH_NOTIFY_FILES}" | grep '^Dockerfile' || true)
CONTAINER_IMAGE_ONLY_FILES=""
while IFS= read -r file; do
  [[ -z "${file}" ]] && continue
  if line_in_list "${file}" "${TEKTON_FILES}"; then
    continue
  fi
  if line_in_list "${file}" "${SECURITY_FILES}"; then
    continue
  fi
  append_line CONTAINER_IMAGE_ONLY_FILES "${file}"
done < <(printf '%s\n' "${IMAGE_FILES}")
CONTAINER_IMAGE_ONLY_FILES=$(printf '%s\n' "${CONTAINER_IMAGE_ONLY_FILES}" | unique_lines || true)
CONTAINER_FILES=$(printf '%s\n%s\n' "${DOCKER_FILES}" "${CONTAINER_IMAGE_ONLY_FILES}" | unique_lines || true)
NOTIFY_FILES=$(printf '%s\n%s\n%s\n' "${TEKTON_FILES}" "${SECURITY_FILES}" "${CONTAINER_FILES}" | unique_lines || true)

if [[ -z "${NOTIFY_FILES}" ]]; then
  echo "PR #${PR_NUMBER} has no policy-relevant changes — no notification sent."
  exit 0
fi

if [[ -z "${SLACK_WEBHOOK_URL}" ]]; then
  echo "SLACK_WEBHOOK_URL is not configured — skipped. Set it to the K8s secret value to enable notifications."
  exit 0
fi

FILE_COUNT=$(count_lines "${NOTIFY_FILES}")

SECTIONS=""
if [[ -n "${TEKTON_FILES}" ]]; then
  TKN_COUNT=$(count_lines "${TEKTON_FILES}")
  append_line SECTIONS ":gear: *Tekton Pipelines* (${TKN_COUNT} file(s))"
  append_line SECTIONS "$(format_section_body "${TEKTON_FILES}")"
  append_line SECTIONS ""
fi
if [[ -n "${CONTAINER_FILES}" ]]; then
  CONTAINER_COUNT=$(count_lines "${CONTAINER_FILES}")
  append_line SECTIONS ":whale: *Container Image Changes* (${CONTAINER_COUNT} file(s))"
  append_line SECTIONS "$(format_section_body "${CONTAINER_FILES}")"
  append_line SECTIONS ""
fi
if [[ -n "${SECURITY_FILES}" ]]; then
  SEC_COUNT=$(count_lines "${SECURITY_FILES}")
  append_line SECTIONS ":lock: *Security Config* (${SEC_COUNT} file(s))"
  append_line SECTIONS "$(format_section_body "${SECURITY_FILES}")"
  append_line SECTIONS ""
fi
SECTIONS="${SECTIONS%$'\n'}"

CHANGE_SUMMARY=""
if [[ -n "${AI_SUMMARY}" ]]; then
  CHANGE_SUMMARY=$(truncate_text "${AI_SUMMARY}" 2800)
else
  if [[ -n "${IMAGE_MATCHES}" ]]; then
    while IFS=$'\t' read -r file snippet; do
      [[ -z "${file}" || -z "${snippet}" ]] && continue
      normalized=$(printf '%s' "${snippet}" | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
      normalized=$(truncate_text "${normalized}" 140)
      append_line CHANGE_SUMMARY ":whale: ${file}: \`${normalized}\`"
    done < <(printf '%s\n' "${IMAGE_MATCHES}" | head -n 6)
  fi

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if line_in_list "${file}" "${IMAGE_FILES}"; then
      continue
    fi
    append_line CHANGE_SUMMARY ":gear: Updated Tekton pipeline definition in \`${file}\`"
  done < <(printf '%s\n' "${TEKTON_FILES}")

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    append_line CHANGE_SUMMARY ":lock: Updated security configuration in \`${file}\`"
  done < <(printf '%s\n' "${SECURITY_FILES}")

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if [[ "${file}" != Dockerfile* ]]; then
      continue
    fi
    if line_in_list "${file}" "${IMAGE_FILES}"; then
      continue
    fi
    append_line CHANGE_SUMMARY ":whale: Updated container build definition in \`${file}\`"
  done < <(printf '%s\n' "${DOCKER_FILES}")

  CHANGE_SUMMARY=$(printf '%s\n' "${CHANGE_SUMMARY}" | sed '/^$/d' | head -n 8 || true)
  if [[ -z "${CHANGE_SUMMARY}" ]]; then
    CHANGE_SUMMARY=":mag: Policy-relevant files changed, but no concise diff summary was available."
  fi
fi

REPO_NAME="${PAC_REPO_URL##*/}"
REPO_NAME="${REPO_NAME%.git}"
REPO_NAME="${REPO_NAME:-repository}"
RAW_PR_TITLE="${PAC_PR_TITLE:-}"
CLEAN_PR_TITLE=$(normalize_pr_title "${PR_NUMBER}" "${RAW_PR_TITLE}")
if [[ -n "${CLEAN_PR_TITLE}" ]]; then
  PR_HEADING="PR #${PR_NUMBER}: ${CLEAN_PR_TITLE}"
else
  PR_HEADING="PR #${PR_NUMBER}"
fi

if [[ -n "${AI_SUMMARY}" ]]; then
  SUMMARY_LABEL=":robot_face: AI Analysis"
else
  SUMMARY_LABEL="Change Summary"
fi

PAYLOAD=$(jq -n \
  --arg pr_number "${PR_NUMBER}" \
  --arg pr_heading "${PR_HEADING}" \
  --arg pr_url "${PR_URL}" \
  --arg sections "${SECTIONS}" \
  --arg count "${FILE_COUNT}" \
  --arg repo "${REPO_NAME}" \
  --arg summary "${CHANGE_SUMMARY}" \
  --arg summary_label "${SUMMARY_LABEL}" \
  '{
    blocks: [
      {
        type: "header",
        text: { type: "plain_text", text: ":rotating_light: Pipeline & Security Change Alert" }
      },
      {
        type: "context",
        elements: [
          { type: "mrkdwn", text: "Detected by *Pipelines-as-Code AI Agent* in *\($repo)*" }
        ]
      },
      { type: "divider" },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: (if $pr_url != "" then ":memo: *<\($pr_url)|\($pr_heading)>*" else ":memo: *\($pr_heading)*" end)
        }
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: $sections
        }
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "*\($summary_label):*\n\($summary)"
        }
      },
      { type: "divider" },
      {
        type: "context",
        elements: [
          { type: "mrkdwn", text: ":rotating_light: *\($count) file(s)* modified across policy boundaries — *requires human approval* before merging" }
        ]
      }
    ]
  }')

curl -sf -X POST -H 'Content-type: application/json' --data "${PAYLOAD}" "${SLACK_WEBHOOK_URL}"
echo "Slack notification sent for PR #${PR_NUMBER} (${FILE_COUNT} policy-relevant file(s) changed)."
