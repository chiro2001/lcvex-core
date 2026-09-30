# Tracked B25 volatile board runner

This directory contains the source-only, fail-closed runner derived byte-for-byte from the
T-20260920-036 sealed bundle and then parameterized by T-20260920-040. Proprietary Quartus
binaries, JTAG server DLLs, SOFs and run logs are deliberately not stored here.

Every hardware run requires a task-specific `board-contract.json`. Validate and seal it before
any remote access:

```sh
python3 fpga/catapult_a10/tools/board_runner/validate_contract.py \
  --contract build/agents/T-ID/board-contract.json --task-id T-YYYYMMDD-NNN
python3 fpga/catapult_a10/tools/board_runner/seal_manifest.py \
  --task-id T-YYYYMMDD-NNN \
  --contract build/agents/T-ID/board-contract.json \
  --output build/agents/T-ID/script-manifest.json
```

The live wrapper must itself run under the shared GamePC lock. It refuses a reused remote root,
validates PowerShell AST and the byte seal remotely, checks the initial exact golden identity,
performs one candidate transaction and one terminal session, then performs one golden restore.

By default, the initial read-only chain check requires the frozen golden design hash as well as
the cable/JTAG ID/UART/PHY checks. One narrowly scoped exception exists for T-053 only:
`hardware.initial_chain_policy="user_attested_flash_boot"` is accepted only with the fixed
attestation token and exact reviewed T-053 candidate/golden identities. In that mode the initial
standard-server design hash is logged as diagnostic, not treated as live-image proof; cable,
JTAG ID, UART/PHY, SOF hashes, process/port checks, one candidate transaction, one terminal
session, and one final exact-golden transaction remain mandatory. No other task can opt out of
the default hash gate through this mode.

```sh
/home/chiro/projects/.resource-locks/resource-lock run gamepc lcvex T-ID root -- \
  fpga/catapult_a10/tools/board_runner/run_board_once.sh \
  build/agents/T-ID/board-contract.json build/agents/T-ID/run final
```

`contract-example.json` is non-executable fixture data. Copy it outside the tracked tree and
replace every identity with reviewed task evidence. The validator rejects persistent formats,
missing safety flags, malformed hashes, non-fresh task IDs and terminal plans without explicit
startup/command acceptance.

Run the no-hardware checks with:

```sh
make b25-board-runner-check
```

These checks never invoke SSH, Quartus, JTAG, a terminal, reset, power or process termination.
