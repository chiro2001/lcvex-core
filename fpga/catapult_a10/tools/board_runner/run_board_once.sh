#!/usr/bin/env bash
set -u -o pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s CONTRACT_JSON LOCAL_OUTPUT RUN_LABEL\n' "$0" >&2
  exit 64
fi

contract_input="$1"
local_output="$2"
run_label="$3"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ ! ${run_label} =~ ^[A-Za-z0-9_-]+$ ]]; then
  printf 'invalid run label: %s\n' "${run_label}" >&2
  exit 64
fi

mkdir -p "${local_output}"
contract="${local_output}/board-contract.json"
manifest="${local_output}/script-manifest.json"
run_dir="${local_output}/${run_label}"
if [[ -e ${run_dir} ]]; then
  printf 'run directory already exists; refusing overwrite: %s\n' "${run_dir}" >&2
  exit 2
fi
mkdir -p "${run_dir}"
summary="${run_dir}/summary.txt"

setup_status=0
if ! python3 "${script_dir}/validate_contract.py" --contract "${contract_input}" \
    >"${run_dir}/contract-validation.log" 2>&1; then
  setup_status=1
else
  if [[ $(readlink -f -- "${contract_input}") != $(readlink -m -- "${contract}") ]]; then
    if ! cp -- "${contract_input}" "${contract}"; then
      setup_status=1
    fi
  fi
fi

if [[ ${setup_status} -eq 0 ]]; then
  task_id=$(jq -er '.task_id' "${contract}") || setup_status=1
  remote_host=$(jq -er '.remote.host' "${contract}") || setup_status=1
  task_root=$(jq -er '.remote.task_root' "${contract}") || setup_status=1
  bootstrap_remote_path=$(jq -er '.remote.bootstrap_path' "${contract}") || setup_status=1
  terminal_to_golden_delay_s=$(jq -er '.hardware.terminal_to_golden_delay_s' "${contract}") || setup_status=1
else
  task_id=UNKNOWN
  remote_host=UNKNOWN
  task_root=UNKNOWN
  bootstrap_remote_path=UNKNOWN
  terminal_to_golden_delay_s=0
fi

printf 'TASK=%s\nTASK_ROOT=%s\nREMOTE_HOST=%s\nRUN_LABEL=%s\nCONTRACT=%s\n' \
  "${task_id}" "${task_root}" "${remote_host}" "${run_label}" "${contract}" >"${summary}"

if [[ ${setup_status} -eq 0 ]] && ! bash -n "${script_dir}/run_board_once.sh" \
    >"${run_dir}/bash-n.log" 2>&1; then
  setup_status=1
fi
if [[ ${setup_status} -eq 0 ]] && ! python3 -m py_compile \
    "${script_dir}/direct_terminal.py" "${script_dir}/seal_manifest.py" \
    "${script_dir}/validate_contract.py" >"${run_dir}/python-compile.log" 2>&1; then
  setup_status=1
fi
if [[ ${setup_status} -eq 0 ]] && ! python3 "${script_dir}/seal_manifest.py" \
    --task-id "${task_id}" --tools-root "${script_dir}" --contract "${contract}" \
    --output "${manifest}" >"${run_dir}/local-seal.log" 2>&1; then
  setup_status=1
fi
if [[ ${setup_status} -eq 0 ]] && ! jq -e --arg task "${task_id}" \
    '.schema_version == 2 and .task_id == $task and (.files | length) == 12 and
     ([.files[].name] | length == (unique | length)) and
     ([.files[].name] | index("board-contract.json") != null)' \
    "${manifest}" >"${run_dir}/manifest-check.log" 2>&1; then
  setup_status=1
fi

if [[ ${setup_status} -ne 0 ]]; then
  printf '%s\n' 'FLOW=BLOCKED_LOCAL_VALIDATION_NO_REMOTE_NO_HARDWARE' >>"${summary}"
  exit 2
fi
printf '%s\n' 'LOCAL_VALIDATION=PASS' >>"${summary}"

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" cmd.exe /d /c \
  "if exist \"${bootstrap_remote_path}\" (exit /b 11) else if exist \"${task_root}\" (exit /b 12) else (exit /b 0)" \
  >"${run_dir}/remote-freshness.log" 2>&1
remote_fresh_status=$?
printf 'REMOTE_FRESHNESS_STATUS=%s\n' "${remote_fresh_status}" >>"${summary}"
if [[ ${remote_fresh_status} -ne 0 ]]; then
  printf '%s\n' 'FLOW=BLOCKED_REMOTE_FRESHNESS_NO_HARDWARE' >>"${summary}"
  exit 2
fi

scp -q -o BatchMode=yes -o ConnectTimeout=10 \
  "${script_dir}/prepare_task_root.ps1" "${remote_host}:${bootstrap_remote_path}" \
  >"${run_dir}/bootstrap-upload.log" 2>&1
bootstrap_upload_status=$?
if [[ ${bootstrap_upload_status} -ne 0 ]]; then
  printf 'BOOTSTRAP_UPLOAD_STATUS=%s\nFLOW=BLOCKED_BOOTSTRAP_UPLOAD_NO_HARDWARE\n' \
    "${bootstrap_upload_status}" >>"${summary}"
  exit 2
fi

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${bootstrap_remote_path}" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" \
  >"${run_dir}/bootstrap.log" 2>&1
bootstrap_status=$?
if [[ ${bootstrap_status} -ne 0 ]]; then
  printf 'BOOTSTRAP_STATUS=%s\nFLOW=BLOCKED_BOOTSTRAP_NO_HARDWARE\n' \
    "${bootstrap_status}" >>"${summary}"
  exit 2
fi

remote_incoming="${task_root}/incoming"
scp -q -o BatchMode=yes -o ConnectTimeout=10 \
  "${script_dir}/contract_common.ps1" \
  "${script_dir}/prepare_task_root.ps1" \
  "${script_dir}/validate_scripts.ps1" \
  "${script_dir}/verify_seal.ps1" \
  "${script_dir}/preflight.ps1" \
  "${script_dir}/program_once.ps1" \
  "${script_dir}/postflight.ps1" \
  "${script_dir}/direct_terminal.py" \
  "${script_dir}/run_board_once.sh" \
  "${script_dir}/seal_manifest.py" \
  "${script_dir}/validate_contract.py" \
  "${contract}" "${manifest}" "${remote_host}:${remote_incoming}/" \
  >"${run_dir}/bundle-upload.log" 2>&1
bundle_upload_status=$?
if [[ ${bundle_upload_status} -ne 0 ]]; then
  printf 'BUNDLE_UPLOAD_STATUS=%s\nFLOW=BLOCKED_BUNDLE_UPLOAD_NO_HARDWARE\n' \
    "${bundle_upload_status}" >>"${summary}"
  exit 2
fi

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${remote_incoming}/validate_scripts.ps1" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" \
  >"${run_dir}/remote-ast.log" 2>&1
ast_status=$?
printf 'AST_VALIDATE_STATUS=%s\n' "${ast_status}" >>"${summary}"
if [[ ${ast_status} -ne 0 ]]; then
  printf '%s\n' 'FLOW=BLOCKED_REMOTE_AST_NO_HARDWARE' >>"${summary}"
  exit 2
fi

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${remote_incoming}/verify_seal.ps1" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" \
  >"${run_dir}/remote-seal.log" 2>&1
seal_status=$?
printf 'REMOTE_SEAL_STATUS=%s\n' "${seal_status}" >>"${summary}"
if [[ ${seal_status} -ne 0 ]]; then
  printf '%s\n' 'FLOW=BLOCKED_REMOTE_SEAL_NO_HARDWARE' >>"${summary}"
  exit 2
fi

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${remote_incoming}/preflight.ps1" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" \
  -ContractPath "${remote_incoming}/board-contract.json" \
  >"${run_dir}/preflight.log" 2>&1
preflight_status=$?
printf 'PREFLIGHT_STATUS=%s\n' "${preflight_status}" >>"${summary}"
if [[ ${preflight_status} -ne 0 ]]; then
  printf '%s\n' 'FLOW=BLOCKED_PREFLIGHT_NO_HARDWARE' >>"${summary}"
  exit 2
fi

candidate_label="${run_label}-candidate"
ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${remote_incoming}/program_once.ps1" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" -Mode candidate -RunLabel "${candidate_label}" \
  -ContractPath "${remote_incoming}/board-contract.json" \
  >"${run_dir}/candidate-program.log" 2>&1
candidate_status=$?
printf 'CANDIDATE_STATUS=%s\n' "${candidate_status}" >>"${summary}"

terminal_status=125
if [[ ${candidate_status} -eq 0 ]]; then
  python3 "${script_dir}/direct_terminal.py" --contract "${contract}" --task-id "${task_id}" \
    --output-dir "${run_dir}" --run-label "${run_label}-terminal" \
    >"${run_dir}/terminal-run.log" 2>&1
  terminal_status=$?
  printf 'TERMINAL_STATUS=%s\n' "${terminal_status}" >>"${summary}"
else
  printf '%s\n' 'TERMINAL_SKIPPED=candidate-program-failed' >>"${summary}"
fi

# Give the direct MPSSE terminal a contract-bound quiescence window before the
# one golden programming attempt. This is a wait for external hardware, not a retry.
if [[ ${terminal_to_golden_delay_s} -gt 0 ]]; then
  sleep "${terminal_to_golden_delay_s}"
fi

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${remote_incoming}/program_once.ps1" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" -Mode golden -RunLabel "${run_label}-golden" \
  -ContractPath "${remote_incoming}/board-contract.json" \
  >"${run_dir}/golden-restore.log" 2>&1
golden_status=$?
printf 'GOLDEN_STATUS=%s\n' "${golden_status}" >>"${summary}"

ssh -n -o BatchMode=yes -o ConnectTimeout=10 "${remote_host}" \
  pwsh.exe -NoLogo -NoProfile -NonInteractive -File "${remote_incoming}/postflight.ps1" \
  -TaskId "${task_id}" -TaskRoot "${task_root}" \
  -ContractPath "${remote_incoming}/board-contract.json" \
  >"${run_dir}/postflight.log" 2>&1
postflight_status=$?
printf 'POSTFLIGHT_STATUS=%s\n' "${postflight_status}" >>"${summary}"

mkdir -p "${run_dir}/remote-evidence"
scp -q -o BatchMode=yes -o ConnectTimeout=10 -r \
  "${remote_host}:${task_root}/program-candidate-${candidate_label}" \
  "${run_dir}/remote-evidence/" >"${run_dir}/fetch-candidate.log" 2>&1
fetch_candidate_status=$?
scp -q -o BatchMode=yes -o ConnectTimeout=10 -r \
  "${remote_host}:${task_root}/program-golden-${run_label}-golden" \
  "${run_dir}/remote-evidence/" >"${run_dir}/fetch-golden.log" 2>&1
fetch_golden_status=$?
scp -q -o BatchMode=yes -o ConnectTimeout=10 \
  "${remote_host}:${task_root}/candidate-quartus-pgm.once" \
  "${remote_host}:${task_root}/golden-quartus-pgm.once" \
  "${remote_host}:${task_root}/postflight-result.json" \
  "${run_dir}/" >"${run_dir}/fetch-final.log" 2>&1
fetch_final_status=$?
printf 'FETCH_CANDIDATE_STATUS=%s\nFETCH_GOLDEN_STATUS=%s\nFETCH_FINAL_STATUS=%s\n' \
  "${fetch_candidate_status}" "${fetch_golden_status}" "${fetch_final_status}" >>"${summary}"

candidate_result="${run_dir}/remote-evidence/program-candidate-${candidate_label}/runtime/program-result.json"
golden_result="${run_dir}/remote-evidence/program-golden-${run_label}-golden/runtime/program-result.json"
candidate_invocations=$(jq -r '.candidate_quartus_pgm_invocation_count // 0' "${candidate_result}" 2>/dev/null || printf '0')
golden_invocations=$(jq -r '.golden_quartus_pgm_invocation_count // 0' "${golden_result}" 2>/dev/null || printf '0')
printf 'CANDIDATE_QUARTUS_PGM_INVOCATIONS=%s\nGOLDEN_QUARTUS_PGM_INVOCATIONS=%s\n' \
  "${candidate_invocations}" "${golden_invocations}" >>"${summary}"

if [[ ${candidate_status} -eq 0 && ${terminal_status} -eq 0 && ${golden_status} -eq 0 &&
      ${postflight_status} -eq 0 && ${fetch_candidate_status} -eq 0 &&
      ${fetch_golden_status} -eq 0 && ${fetch_final_status} -eq 0 &&
      ${candidate_invocations} -eq 1 && ${golden_invocations} -eq 1 ]]; then
  printf '%s\n' 'FLOW=PASS_CANDIDATE_FUNCTIONAL_AND_GOLDEN_RESTORED' >>"${summary}"
  exit 0
fi
if [[ ${golden_status} -eq 0 && ${postflight_status} -eq 0 ]]; then
  printf '%s\n' 'FLOW=FUNCTIONAL_FAIL_OR_GOLDEN_RESTORE_PASS' >>"${summary}"
else
  printf '%s\n' 'FLOW=FAIL_GOLDEN_RESTORE_NOT_PROVEN' >>"${summary}"
fi
exit 1
