#!/usr/bin/env bash
#
# The whole EVM deployment, start to finish, on a throwaway chain.
#
# Deploys stand in rails, runs phase one, proves the timelock refuses an early execution, warps
# past it, runs phase two, verifies the chain against the record, and sends one real transfer
# through the result. Every step fails loudly.
#
# This exists because the things that break a deployment are not syntax errors. They are an action
# queued with a field the router refuses, a lane set in the wrong order, a record whose keys do not
# match what phase two reads back, and a hook the far side cannot parse. None of those show up in a
# compile and all of them show up here, in under a minute, for free.
#
# Chain time semantics: this local EVM chain advances time only through evm_increaseTime, so the
# timelock warp below is explicit and deterministic. The Stellar side (ledger time) is not exercised
# here and must be validated separately.
#
# This local harness is not activation evidence: the active deployment gate remains Stellar
# Testnet outbound ITS/CCTP. Adapter-owner controls here are distinct from router timelocks.
#
# Usage: script/anvil-e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# Respect a caller's reviewed toolchain; the default install is a fallback.
export PATH="$PATH:$HOME/.foundry/bin"

RPC="${RPC:-http://127.0.0.1:8545}"
EVM_DIR="evm"
HYPERION_FAULT_SEED="${HYPERION_FAULT_SEED:-156}"
export HYPERION_FAULT_SEED
node -e 'const seed=process.env.HYPERION_FAULT_SEED;if(!/^[0-9]+$/.test(seed)||BigInt(seed)>((1n<<64n)-1n))process.exit(1)' \
  || { printf 'HYPERION_FAULT_SEED must be an unsigned 64-bit integer\n' >&2; exit 1; }

note() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mfailed: %s\033[0m\n' "$*" >&2; exit 1; }

for tool in forge cast anvil node; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  note "using the node already listening on $RPC"
else
  note "starting anvil"
  anvil --silent --block-time 1 > /tmp/hyperion-anvil.log 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 30); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 1
  done
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || die "anvil did not come up"
fi

CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN_ID" = "31337" ] || [ "$CHAIN_ID" = "1337" ] || die "chain $CHAIN_ID is not a local node; this script deploys a mintable token called USDC and that belongs nowhere else"

# Anvil's first three well known accounts. Public, documented, funded only on a throwaway chain.
# They appear here and nowhere else in this repository.
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
GUARDIAN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TREASURY=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

json() { node -e 'const f=require("fs");process.stdout.write(String(JSON.parse(f.readFileSync(process.argv[1],"utf8"))[process.argv[2]]))' "$1" "$2"; }

note "deploying stand in rails"
note "using deterministic provider fault schedule (seed ${HYPERION_FAULT_SEED})"
( cd "$EVM_DIR" && forge test --match-contract RouterProviderFaultTest --fuzz-seed "$HYPERION_FAULT_SEED" ) \
  > /tmp/hyperion-provider-faults.log 2>&1 \
  || { tail -30 /tmp/hyperion-provider-faults.log; die "seeded provider rollback/retry rehearsal"; }
( cd "$EVM_DIR" && mkdir -p deployments && forge script script/LocalRails.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$SENDER" >/tmp/hyperion-rails.log 2>&1 ) \
  || { tail -30 /tmp/hyperion-rails.log; die "LocalRails"; }

RAILS="$EVM_DIR/deployments/local-rails.json"
export HYPERION_TOKEN=$(json "$RAILS" token)
export CCTP_TOKEN_MESSENGER=$(json "$RAILS" cctpTokenMessenger)
export CCTP_MESSAGE_TRANSMITTER=$(json "$RAILS" cctpMessageTransmitter)
export AXELAR_ITS=$(json "$RAILS" axelarIts)
export AXELAR_GAS_SERVICE=$(json "$RAILS" axelarGasService)
export AXELAR_TOKEN_ID=$(json "$RAILS" axelarTokenId)
echo "  token      $HYPERION_TOKEN"
echo "  messenger  $CCTP_TOKEN_MESSENGER"
echo "  its        $AXELAR_ITS"

export HYPERION_ADMIN="$SENDER"
export HYPERION_GUARDIAN="$GUARDIAN"
export HYPERION_TREASURY="$TREASURY"
export HYPERION_FEE_BPS=30
# The contract floor, so the wait below is as short as the router allows.
export HYPERION_TIMELOCK_DELAY=3600
export HYPERION_FLOW_WINDOW=3600
export HYPERION_TOKEN_DECIMALS=6
export HYPERION_TOKEN_FLOW_LIMIT=1000000000000
export HYPERION_TOKEN_SYMBOL=USDC
export HYPERION_STELLAR_CHAIN=stellar-testnet
export AXELAR_STELLAR_CHAIN=stellar
# Stands in for the Soroban router's contract id. A real run takes this from the Stellar half's
# deployment record, which is why neither side can be deployed without reference to the other.
export STELLAR_RAIL_RECIPIENT=0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10
export STELLAR_AXELAR_PEER=0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10
# Local stand-in for the 32-byte Stellar CCTP USDC asset identity. It is stored in the
# deployment record and compared through phase two and verification; it never claims to be a
# real testnet/mainnet asset identity.
export STELLAR_CCTP_TOKEN=0x0000000000000000000000000000000000000000000000000000000000000001

note "phase one: deploy and queue"
DEPLOY_LOG=/tmp/hyperion-deploy.log
if ! ( cd "$EVM_DIR" && forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$SENDER" ) \
  >"$DEPLOY_LOG" 2>&1; then
  cat "$DEPLOY_LOG"
  die "Deploy"
fi
grep -E '^  (router|cctp adapter|axelar adapter|queued|Queued|record)' "$DEPLOY_LOG" \
  || { cat "$DEPLOY_LOG"; die "Deploy output"; }

note "the timelock has to refuse this"
if ( cd "$EVM_DIR" && forge script script/Execute.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" >/tmp/hyperion-early.log 2>&1 ); then
  die "phase two succeeded before the timelock matured, which means the timelock is not doing anything"
fi
grep -E 'NOT READY|seconds remaining' /tmp/hyperion-early.log | head -2 || die "refused, but not for the reason expected"
echo "  refused, as it should"

note "warping past the timelock"
cast rpc evm_increaseTime 3700 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
sleep 2

note "phase two: execute"
( cd "$EVM_DIR" && forge script script/Execute.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$SENDER" 2>&1 ) \
  | grep -E '^  (executed|already done|CCTP)' || die "Execute"

note "phase two again, to prove it is idempotent"
( cd "$EVM_DIR" && forge script script/Execute.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" 2>&1 ) \
  | grep -E '^  (executed this run|already done)' || die "Execute is not idempotent"

note "verifying the chain against the record"
( cd "$EVM_DIR" && forge script script/Verify.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" 2>&1 ) \
  | grep -E '^  (Everything|BAD|WARN|Mismatches)' || die "Verify"

note "checking deployed capabilities against the snapshot"
RECORD="$EVM_DIR/deployments/evm-$CHAIN_ID-phase1.json"
ROUTER=$(json "$RECORD" router)
[ -n "$ROUTER" ] || die "no router in $RECORD"
route_kind() {
  case "$1" in
    cctp) echo 0 ;;
    axelar-its) echo 1 ;;
    axelar-gmp) echo 2 ;;
    allbridge) echo 3 ;;
    *) die "$1 is not a protocol route slug" ;;
  esac
}
while read -r directive slug; do
  [ "$directive" = "route" ] || continue
  adapter=$(cast call "$ROUTER" "adapter(uint8)(address)" "$(route_kind "$slug")" --rpc-url "$RPC")
  case "$adapter" in
    0x0000000000000000000000000000000000000000) die "the router advertises $slug but has no adapter" ;;
  esac
  echo "  $slug adapter $adapter"
done < testdata/capabilities/evm-router.cap
CCTP=$(json "$RECORD" cctpAdapter)
CCTP_SLUG=$(awk '$1 == "route" { print $2; exit }' testdata/capabilities/evm-cctp-adapter.cap)
[ "$(cast call "$CCTP" 'route()(uint8)' --rpc-url "$RPC")" = "$(route_kind "$CCTP_SLUG")" ] \
  || die "the deployed CCTP adapter does not report its recorded route"
AXELAR=$(json "$RECORD" axelarAdapter)
AXELAR_SLUG=$(awk '$1 == "route" { print $2; exit }' testdata/capabilities/evm-axelar-adapter.cap)
[ "$(cast call "$AXELAR" 'route()(uint8)' --rpc-url "$RPC")" = "$(route_kind "$AXELAR_SLUG")" ] \
  || die "the deployed Axelar adapter does not report its recorded route"
echo "  adapters report the routes the snapshots record"

note "checking the versioned malformed-message corpus"
corpus_cases=$(node script/malformed-message-corpus.mjs \
  | node -e 'let input="";process.stdin.setEncoding("utf8");process.stdin.on("data",chunk=>input+=chunk);process.stdin.on("end",()=>{const cases=JSON.parse(input).cases;if(!Array.isArray(cases)||cases.length===0)process.exitCode=1;else process.stdout.write(String(cases.length));});') \
  || die "malformed-message corpus"
echo "  corpus: $corpus_cases cases"

note "sending one real transfer"
( cd "$EVM_DIR" && forge script script/Smoke.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$SENDER" 2>&1 ) \
  | grep -E '^  (quote available|sent|fee to treasury|What the rail|The hook)|^    (amount burned|destination domain|mint recipient|hook)' || die "Smoke"

printf '\n\033[32mThe whole EVM deployment works on a local chain.\033[0m\n'
