// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {HyperionRouter} from "../src/HyperionRouter.sol";
import {AxelarItsAdapter} from "../src/adapters/AxelarItsAdapter.sol";
import {CctpAdapter} from "../src/adapters/CctpAdapter.sol";

import {RouteKind} from "../src/HyperionTypes.sol";

/// @title Everything a deployment needs to know that is not in the source tree
/// @notice Read from the environment, never from a constant in here, with one exception noted
/// below. A deploy script with addresses baked in is a deploy script that works on one chain and
/// quietly does the wrong thing on the next one, and the wrong thing on a bridge is funds sent to
/// a contract that is not the one anybody meant.
///
/// Every variable is read by name and the read fails loudly when it is missing. Foundry's
/// `envAddress` reverts on an unset key, which is the behaviour this wants: a missing
/// `CCTP_TOKEN_MESSENGER` should stop the deployment, not deploy an adapter pointed at the zero
/// address that reverts on first use.
abstract contract DeployConfig is Script {
    string internal constant VERIFIED_EVM_VERSION = "cancun";
    string internal constant VERIFIED_SOLC_VERSION = "0.8.28";
    string internal constant VERIFIED_SOLC_FULL_VERSION = "0.8.28+commit.7893614a";

    struct CompatibilityProfile {
        string compilerVersion;
        string evmVersion;
        uint256 optimizerRuns;
        bool viaIR;
    }

    /// @dev Read actual compiler metadata from the local artifact selected by compiled creation
    /// code. Environment labels are additional constraints, never evidence about the build.
    function _verifiedArtifactProfile(string memory path)
        internal
        view
        returns (CompatibilityProfile memory)
    {
        return _validateArtifactProfileJson(vm.readFile(path));
    }

    function _validateArtifactProfileJson(string memory artifact)
        internal
        pure
        returns (CompatibilityProfile memory profile)
    {
        profile.compilerVersion = vm.parseJsonString(artifact, ".metadata.compiler.version");
        profile.evmVersion = vm.parseJsonString(artifact, ".metadata.settings.evmVersion");
        profile.optimizerRuns = vm.parseJsonUint(artifact, ".metadata.settings.optimizer.runs");
        profile.viaIR = vm.parseJsonBool(artifact, ".metadata.settings.viaIR");
        require(
            keccak256(bytes(profile.compilerVersion)) == keccak256(bytes(VERIFIED_SOLC_FULL_VERSION)),
            "artifact compiler revision mismatch"
        );
        require(
            keccak256(bytes(profile.evmVersion)) == keccak256(bytes(VERIFIED_EVM_VERSION)),
            "artifact EVM revision mismatch"
        );
        require(
            vm.parseJsonBool(artifact, ".metadata.settings.optimizer.enabled") && profile.optimizerRuns == 50
                && profile.viaIR,
            "artifact optimizer profile mismatch"
        );
    }
    /// @dev The one hard coded value, and only because Circle assigned it rather than deployed it.
    /// Stellar is domain twenty seven on CCTP. It is not a chain id, not derived from one, and not
    /// configurable, so putting it in the environment would only create a way to get it wrong.
    uint32 internal constant STELLAR_CCTP_DOMAIN = 27;

    /// @dev Hyperion's own name for the Stellar network, which is what the adapters key lanes and
    /// peers on. Lowercase and stable, matching the `ChainKey` union in the protocol package.
    string internal constant STELLAR_CHAIN = "stellar";
    string internal constant STELLAR_TESTNET_CHAIN = "stellar-testnet";

    struct RouterParams {
        address admin;
        address guardian;
        address treasury;
        uint16 feeBps;
        uint64 timelockDelay;
        uint64 flowWindow;
    }

    struct RailParams {
        /// Circle's TokenMessengerV2 on this chain. Burns on the way out, mints on the way in.
        address cctpTokenMessenger;
        /// Circle's MessageTransmitterV2. The contract whose signature check is the trust root.
        address cctpMessageTransmitter;
        /// Axelar's Interchain Token Service, or zero to skip the Axelar adapter entirely.
        address axelarIts;
        /// Axelar's gas service. Required when `axelarIts` is set.
        address axelarGasService;
    }

    struct TokenParams {
        address token;
        uint8 decimals;
        uint256 flowLimit;
        /// Token-wide emergency ceiling. Bounded by `flowLimit`; a tighter value is the point.
        uint256 breakerThreshold;
        string symbol;
    }

    /// @notice Who holds which key, and the three numbers that shape the router's behaviour.
    /// @dev `DEPLOYER_ADDRESS` is deliberately separate from the admin. On a real deployment the
    /// admin is a multisig that cannot run a script, and the deployer is a hot key that should
    /// hold nothing afterwards. On a local chain they are the same account and that is fine.
    function routerParams() internal view returns (RouterParams memory params) {
        params = RouterParams({
            admin: vm.envAddress("HYPERION_ADMIN"),
            guardian: vm.envOr("HYPERION_GUARDIAN", address(0)),
            treasury: vm.envAddress("HYPERION_TREASURY"),
            // Thirty basis points unless told otherwise. The ceiling in `AmountMath` is a
            // hundred, and the constructor checks it, so a fat finger here fails at deploy.
            feeBps: uint16(vm.envOr("HYPERION_FEE_BPS", uint256(30))),
            // Twenty four hours. Long enough that somebody reading the chain has a working day to
            // object, short enough that a genuine fix is not a week away. The contract floor is
            // one hour.
            timelockDelay: uint64(vm.envOr("HYPERION_TIMELOCK_DELAY", uint256(24 hours))),
            // One hour of flow accounting. Sliding, not calendar, so this is a window length
            // rather than a reset time.
            flowWindow: uint64(vm.envOr("HYPERION_FLOW_WINDOW", uint256(1 hours)))
        });
    }

    /// @dev Refuse to queue any deployment action when the compiler/fork assumptions are not the
    /// ones reviewed for this tree. Chain IDs are explicit because a fork can share an ID with a
    /// live network while exposing different opcode and precompile behavior.
    function requireCompatibleExecutionTarget() internal view {
        string memory evmVersion = vm.envOr("HYPERION_EVM_VERSION", string(VERIFIED_EVM_VERSION));
        string memory solcVersion = vm.envOr("HYPERION_SOLC_VERSION", string(VERIFIED_SOLC_VERSION));
        require(
            keccak256(bytes(evmVersion)) == keccak256(bytes(VERIFIED_EVM_VERSION)),
            "unsupported EVM revision; use cancun"
        );
        require(
            keccak256(bytes(solcVersion)) == keccak256(bytes(VERIFIED_SOLC_VERSION)),
            "unsupported compiler revision; use 0.8.28"
        );
        require(
            block.chainid == 31_337 || block.chainid == 1337 || block.chainid == 11_155_111
                || block.chainid == 84_532 || block.chainid == 5_042_002,
            "unsupported deployment chain"
        );
        _verifiedArtifactProfile(vm.getArtifactPathByCode(type(HyperionRouter).creationCode));
        _verifiedArtifactProfile(vm.getArtifactPathByCode(type(CctpAdapter).creationCode));
        _verifiedArtifactProfile(vm.getArtifactPathByCode(type(AxelarItsAdapter).creationCode));
    }

    function railParams() internal view returns (RailParams memory params) {
        params = RailParams({
            cctpTokenMessenger: vm.envAddress("CCTP_TOKEN_MESSENGER"),
            cctpMessageTransmitter: vm.envAddress("CCTP_MESSAGE_TRANSMITTER"),
            axelarIts: vm.envOr("AXELAR_ITS", address(0)),
            axelarGasService: vm.envOr("AXELAR_GAS_SERVICE", address(0))
        });
    }

    /// @notice The asset this deployment routes, and the ceiling it routes under.
    /// @dev One token per run on purpose. Registering a second is a queued action against a live
    /// router, which is a different operation with a different review, and pretending otherwise
    /// by looping here would hide that.
    function tokenParams() internal view returns (TokenParams memory params) {
        uint256 flowLimit = vm.envUint("HYPERION_TOKEN_FLOW_LIMIT");
        params = TokenParams({
            token: vm.envAddress("HYPERION_TOKEN"),
            decimals: uint8(vm.envUint("HYPERION_TOKEN_DECIMALS")),
            flowLimit: flowLimit,
            // Half the ordinary ceiling unless stated. The breaker is meant to be the tighter
            // boundary; a deployment that wants it equal to the flow limit can say so.
            breakerThreshold: vm.envOr("HYPERION_TOKEN_BREAKER_THRESHOLD", flowLimit / 2),
            symbol: vm.envOr("HYPERION_TOKEN_SYMBOL", string("USDC"))
        });
    }

    /// @notice Hyperion's name for the Stellar network this chain is paired with.
    function stellarChain() internal view returns (string memory) {
        return vm.envOr("HYPERION_STELLAR_CHAIN", string(STELLAR_TESTNET_CHAIN));
    }

    /// @notice Axelar's own name for the Stellar network, which is not always Hyperion's name.
    /// @dev No default. The adapter stores whatever string it is given and compares inbound
    /// deliveries against it, so a plausible guess here is a peer check that passes for the wrong
    /// contract. If Axelar is being wired up, this has to be stated.
    function axelarStellarChain() internal view returns (string memory) {
        return vm.envString("AXELAR_STELLAR_CHAIN");
    }

    /// @notice Hyperion's router on Stellar, as the thirty two bytes a rail puts on the wire.
    /// @dev A Soroban contract id. CCTP's mint recipient slot is thirty two bytes with no room for
    /// a kind tag, which is why the destination the recipient actually wanted travels in the hook
    /// instead and this slot names the adapter.
    function stellarRailRecipient() internal view returns (bytes32) {
        return vm.envBytes32("STELLAR_RAIL_RECIPIENT");
    }

    function stellarCctpToken() internal view returns (bytes32) {
        return vm.envBytes32("STELLAR_CCTP_TOKEN");
    }

    /// @notice Hyperion's Axelar adapter on Stellar, in the form that chain's ITS puts on the wire.
    function stellarAxelarPeer() internal view returns (bytes memory) {
        return vm.envBytes("STELLAR_AXELAR_PEER");
    }

    /// @notice The ITS token id this chain's asset is registered under.
    /// @dev The same value on every chain ITS connects, which is the whole point of an id. The
    /// adapter asks ITS whether the id really does belong to this token before storing it, so a
    /// typo fails at configuration rather than at delivery.
    function axelarTokenId() internal view returns (bytes32) {
        return vm.envBytes32("AXELAR_TOKEN_ID");
    }

    /// @notice Which rails this run wires up.
    function wiresAxelar() internal view returns (bool) {
        RailParams memory rails = railParams();
        return rails.axelarIts != address(0) && rails.axelarGasService != address(0);
    }

    /// @dev `RouteKind` as the integer that goes in a filename or a JSON key.
    function routeSlug(RouteKind route) internal pure returns (string memory) {
        if (route == RouteKind.Cctp) return "cctp";
        if (route == RouteKind.AxelarIts) return "axelar-its";
        if (route == RouteKind.AxelarGmp) return "axelar-gmp";
        return "allbridge";
    }
}
