#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NOTIFIER="${SCRIPT_DIR}/../scripts/notify-tekton-changes.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "assert_contains failed: missing '${needle}'" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "assert_not_contains failed: found '${needle}'" >&2
    exit 1
  fi
}

make_fake_bin() {
  local root="$1"
  mkdir -p "${root}"

  cat >"${root}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${GH_API_RESPONSE-}"
EOF

  cat >"${root}/curl" <<'EOF'
#!/usr/bin/env bash
payload=""
prev=""
for arg in "$@"; do
  if [[ "${prev}" == "--data" ]]; then
    payload="${arg}"
    break
  fi
  prev="${arg}"
done
printf '%s' "${payload}" > "${CURL_CAPTURE_FILE}"
EOF

  chmod +x "${root}/gh" "${root}/curl"
}

run_notifier() {
  local fake_bin="$1"
  local gh_response="$2"
  local changed_files="$3"
  local webhook="${4-https://hooks.slack.test/services/demo}"
  local capture_file="${5:-}"
  local ai_summary="${6:-}"
  local pr_title="${7-Test PR}"
  local ai_mode="${8-analysis}"
  local ai_trigger_source="${9-human_pr}"

  if [[ -n "${capture_file}" ]]; then
    rm -f "${capture_file}"
  fi

  (
    export PATH="${fake_bin}:${PATH}"
    export GH_API_RESPONSE="${gh_response}"
    export CURL_CAPTURE_FILE="${capture_file}"
    export PAC_LLM_EXECUTION_CONTEXT=ci
    export PAC_PR_NUMBER=42
    export PAC_PR_TITLE="${pr_title}"
    export PAC_REPO_URL="https://github.com/pipelines-as-code/ai-demo-app"
    export PAC_REPO_OWNER="pipelines-as-code"
    export PAC_REPO_NAME="ai-demo-app"
    export PAC_AI_MODE="${ai_mode}"
    export PAC_AI_TRIGGER_SOURCE="${ai_trigger_source}"
    export SLACK_WEBHOOK_URL="${webhook}"
    if [[ -n "${changed_files}" ]]; then
      export PAC_CHANGED_FILES_B64
      PAC_CHANGED_FILES_B64=$(printf '%s' "${changed_files}" | base64 | tr -d '\n')
    else
      unset PAC_CHANGED_FILES_B64
    fi
    if [[ -n "${ai_summary}" ]]; then
      export PAC_CHANGE_SUMMARY="${ai_summary}"
    else
      unset PAC_CHANGE_SUMMARY
    fi
    bash "${NOTIFIER}"
  )
}

main() {
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf -- '"'"${temp_dir}"'"'' EXIT
  make_fake_bin "${temp_dir}/bin"

  local output=""
  local payload_file=""
  payload_file="${temp_dir}/payload-tekton.json"
  output=$(run_notifier "${temp_dir}/bin" '[{"filename":".tekton/pipeline.yaml","patch":"@@\n+taskRunSpecs: []"}]' '.tekton/pipeline.yaml' 'https://hooks.slack.test/services/demo' "${payload_file}")
  assert_contains "${output}" "Slack notification sent for PR #42"
  assert_contains "$(cat "${payload_file}")" "Tekton Pipelines"
  assert_contains "$(cat "${payload_file}")" 'Updated Tekton pipeline definition in `.tekton/pipeline.yaml`'
  assert_not_contains "$(cat "${payload_file}")" "Container Image Changes"

  payload_file="${temp_dir}/payload-security.json"
  output=$(run_notifier "${temp_dir}/bin" '[{"filename":"security/policy.yaml","patch":"@@\n+enforcement: enabled"}]' 'security/policy.yaml' 'https://hooks.slack.test/services/demo' "${payload_file}")
  assert_contains "$(cat "${payload_file}")" "Security Config"
  assert_contains "$(cat "${payload_file}")" 'Updated security configuration in `security/policy.yaml`'

  payload_file="${temp_dir}/payload-docker.json"
  output=$(run_notifier "${temp_dir}/bin" '[{"filename":"Dockerfile","patch":"@@\n-FROM docker.io/library/openjdk:17\n+FROM registry.access.redhat.com/ubi8/openjdk-17:1.20"}]' 'Dockerfile' 'https://hooks.slack.test/services/demo' "${payload_file}")
  assert_contains "$(cat "${payload_file}")" "Container Image Changes"
  assert_contains "$(cat "${payload_file}")" "Dockerfile"
  assert_contains "$(cat "${payload_file}")" "FROM registry.access.redhat.com/ubi8/openjdk-17:1.20"

  payload_file="${temp_dir}/payload-image-only.json"
  output=$(run_notifier "${temp_dir}/bin" '[{"filename":"deploy/values.yaml","patch":"@@\n-  image: quay.io/example/app:1.0\n+  image: quay.io/example/app:1.1"}]' 'deploy/values.yaml' 'https://hooks.slack.test/services/demo' "${payload_file}")
  assert_contains "${output}" "Slack notification sent for PR #42"
  assert_contains "$(cat "${payload_file}")" "deploy/values.yaml"
  assert_contains "$(cat "${payload_file}")" "image: quay.io/example/app:1.1"

  output=$(run_notifier "${temp_dir}/bin" '[{"filename":"README.md","patch":"@@\n+docs"}]' 'README.md' 'https://hooks.slack.test/services/demo' "${temp_dir}/payload-unrelated.json")
  assert_contains "${output}" "PR #42 has no policy-relevant changes — no notification sent."
  if [[ -e "${temp_dir}/payload-unrelated.json" ]]; then
    echo "unexpected payload for unrelated change" >&2
    exit 1
  fi

  output=$(run_notifier "${temp_dir}/bin" '[{"filename":"Dockerfile","patch":"@@\n+FROM registry.access.redhat.com/ubi8/openjdk-17:1.20"}]' 'Dockerfile' '' "${temp_dir}/payload-no-webhook.json")
  assert_contains "${output}" "SLACK_WEBHOOK_URL is not configured — skipped."
  if [[ -e "${temp_dir}/payload-no-webhook.json" ]]; then
    echo "unexpected payload for missing webhook" >&2
    exit 1
  fi

  output=$(run_notifier "${temp_dir}/bin" '' '' 'https://hooks.slack.test/services/demo' "${temp_dir}/payload-no-metadata.json")
  assert_contains "${output}" "No changed-file metadata available for PR #42 — skipped."
  if [[ -e "${temp_dir}/payload-no-metadata.json" ]]; then
    echo "unexpected payload for missing metadata" >&2
    exit 1
  fi

  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":"Dockerfile","patch":"@@\n+FROM registry.access.redhat.com/ubi8/openjdk-17:1.20"}]' \
    'Dockerfile' \
    'https://hooks.slack.test/services/demo' \
    "${temp_dir}/payload-apply-mode.json" \
    "" \
    "Test PR" \
    "apply")
  assert_contains "${output}" "Slack notification skipped during AI apply mode."
  if [[ -e "${temp_dir}/payload-apply-mode.json" ]]; then
    echo "unexpected payload during apply mode" >&2
    exit 1
  fi

  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":"Dockerfile","patch":"@@\n+FROM registry.access.redhat.com/ubi8/openjdk-17:1.20"}]' \
    'Dockerfile' \
    'https://hooks.slack.test/services/demo' \
    "${temp_dir}/payload-ai-remediation.json" \
    "" \
    "Test PR" \
    "analysis" \
    "ai_remediation")
  assert_contains "${output}" "Slack notification suppressed for AI remediation rerun."
  if [[ -e "${temp_dir}/payload-ai-remediation.json" ]]; then
    echo "unexpected payload during AI remediation rerun" >&2
    exit 1
  fi

  payload_file="${temp_dir}/payload-dedup.json"
  output=$(run_notifier "${temp_dir}/bin" '[{"filename":".tekton/release.yaml","patch":"@@\n-  image: quay.io/example/app:1.0\n+  image: quay.io/example/app:2.0"}]' '.tekton/release.yaml' 'https://hooks.slack.test/services/demo' "${payload_file}")
  assert_contains "${output}" "Slack notification sent for PR #42"
  assert_contains "$(cat "${payload_file}")" "Tekton Pipelines"
  assert_not_contains "$(cat "${payload_file}")" "Container Image Changes"

  payload_file="${temp_dir}/payload-pr-title-prefixed.json"
  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":".tekton/pipeline.yaml","patch":"@@\n+taskRunSpecs: []"}]' \
    '.tekton/pipeline.yaml' \
    'https://hooks.slack.test/services/demo' \
    "${payload_file}" \
    "" \
    "PR #42: Add Slack notifier")
  assert_contains "$(cat "${payload_file}")" "PR #42: Add Slack notifier"
  assert_not_contains "$(cat "${payload_file}")" "PR #42: PR #42: Add Slack notifier"

  payload_file="${temp_dir}/payload-pr-title-empty.json"
  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":".tekton/pipeline.yaml","patch":"@@\n+taskRunSpecs: []"}]' \
    '.tekton/pipeline.yaml' \
    'https://hooks.slack.test/services/demo' \
    "${payload_file}" \
    "" \
    "")
  assert_contains "$(cat "${payload_file}")" "PR #42"
  assert_not_contains "$(cat "${payload_file}")" "PR #42: "

  payload_file="${temp_dir}/payload-ai-summary.json"
  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":".tekton/pipeline.yaml","patch":"@@\n+taskRunSpecs: []"},{"filename":"Dockerfile","patch":"@@\n-FROM registry.access.redhat.com/ubi8/openjdk-17:1.10\n+FROM registry.access.redhat.com/ubi8/openjdk-17:1.20"}]' \
    $'.tekton/pipeline.yaml\nDockerfile' \
    'https://hooks.slack.test/services/demo' \
    "${payload_file}" \
    $'This PR adds the Slack notifier workflow and updates the base image for the application build.\n\nReview focus for the whole PR: confirm the notifier only triggers for policy-relevant changes and that the UBI image update remains compatible with the pipeline tasks.' \
    "Add Slack notifier and update base image")
  assert_contains "${output}" "Slack notification sent for PR #42"
  assert_contains "$(cat "${payload_file}")" "AI Analysis"
  assert_contains "$(cat "${payload_file}")" "Review focus for the whole PR"
  assert_not_contains "$(cat "${payload_file}")" "Updated Tekton pipeline definition"

  payload_file="${temp_dir}/payload-ai-summary-image-only.json"
  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":"deploy/values.yaml","patch":"@@\n-  image: quay.io/example/app:1.0\n+  image: quay.io/example/app:1.1"}]' \
    'deploy/values.yaml' \
    'https://hooks.slack.test/services/demo' \
    "${payload_file}" \
    $'This PR updates the deployment image reference from `quay.io/example/app:1.0` to `quay.io/example/app:1.1`.\n\nReview focus for the whole PR: verify the new image tag is approved and aligned with the release intent.' \
    "Update deployment image")
  assert_contains "${output}" "Slack notification sent for PR #42"
  assert_contains "$(cat "${payload_file}")" "AI Analysis"
  assert_contains "$(cat "${payload_file}")" "deployment image reference"
  assert_not_contains "$(cat "${payload_file}")" "image: quay.io/example/app:1.1"

  payload_file="${temp_dir}/payload-no-ai-summary.json"
  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":".tekton/pipeline.yaml","patch":"@@\n+taskRunSpecs: []"}]' \
    '.tekton/pipeline.yaml' \
    'https://hooks.slack.test/services/demo' \
    "${payload_file}" \
    "")
  assert_contains "$(cat "${payload_file}")" "Updated Tekton pipeline definition"
  assert_not_contains "$(cat "${payload_file}")" "AI Analysis"

  payload_file="${temp_dir}/payload-footer.json"
  output=$(run_notifier "${temp_dir}/bin" \
    '[{"filename":"security/policy.yaml","patch":"@@\n+enforcement: enabled"}]' \
    'security/policy.yaml' \
    'https://hooks.slack.test/services/demo' \
    "${payload_file}")
  assert_contains "$(cat "${payload_file}")" "requires human approval"

  echo "ok"
}

main "$@"
