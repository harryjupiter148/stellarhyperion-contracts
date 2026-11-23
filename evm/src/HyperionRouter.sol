// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin/access/AccessControl.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";

import {
    AdapterIdentityMismatch,
    AdapterMethodUnavailable,
    AdapterNotSet,
    AmountNotRepresentable,
    ClaimAlreadySettled,
    ClaimNotFound,
    FeeTooHigh,
    InvalidAmount,
    InvalidLimit,
    InvalidRelayerFee,
    InvalidWindow,
    LimitNotRaised,
    NoRefundCredit,
    NotRailReceiver,
    ProviderBudgetExceeded,
    RecipientNotReady,
    RefundFailed,
    ReplayedMessage,
    StaleMapping,
    TimelockAlreadyExecuted,
    TimelockDelayOutOfRange,
    TimelockExpired,
    TimelockNotQueued,
    TimelockNotReady,
    TokenNotRegistered,
    Unauthorized,
    ZeroAddress
} from "./HyperionErrors.sol";
import {
    ActionAuditStatus,
    ActionKind,
    AddressKind,
    AdminAction,
    CancelReason,
    ClaimSettlementResult,
    ClaimSettlementStatus,
    Destination,
    Origin,
    OutboundRecord,
    OutboundRequest,
    PendingClaim,
    QueuedAction,
    RouteKind,
    RouteQuote,
    RouteQuoteV2,
    TokenConfig,
    TransferIntent
} from "./HyperionTypes.sol";
import {OutboundProvenance} from "./OutboundProvenance.sol";
import {TokenRecoveryManager} from "./TokenRecoveryManager.sol";
import {IAxelarItsIntentAdapter} from "./interfaces/IAxelarItsIntentAdapter.sol";
import {IHyperionRouter} from "./interfaces/IHyperionRouter.sol";
import {IRailAdapter} from "./interfaces/IRailAdapter.sol";
import {ITokenRecoveryManager} from "./interfaces/ITokenRecoveryManager.sol";
import {AmountMath} from "./libraries/AmountMath.sol";
import {FlowGuard, FlowWindow} from "./libraries/FlowGuard.sol";

/// @title Hyperion, the EVM side
/// @author dotmantissa
/// @notice Hyperion is a router, not a bridge, and the difference is the only thing that matters
/// about it. It never decides whether a cross-chain message is genuine. Circle's attestation
/// service decides that for CCTP, Axelar's validator set decides it for ITS, and Hyperion sits
/// downstream of whichever one is carrying a given transfer, doing the things a rail does not do
/// for you: quoting the four of them side by side, taking a fee it declared up front, keeping a
/// ceiling on how much can move in an hour, and catching funds that arrive for somebody who
/// cannot receive them yet.
///
/// `bridgeIn` is the whole argument in one function. It is callable by exactly one address per
/// rail, that address is the rail's own receiving contract, and it is checked with an equality
/// rather than a role, because there is one right answer per rail and anything looser than one
/// right answer is a mint function with extra steps.
///
/// Everything privileged waits out a timelock, and the two exceptions both only ever make the
/// bridge do less: pausing departures, and lowering a flow limit. Nobody should have to file a
/// change request to slow an exploit down.
contract HyperionRouter is IHyperionRouter, AccessControl, Pausable, ReentrancyGuard {
    /// @notice Maximum claim IDs attempted in one settlement batch.
    uint256 public constant MAX_CLAIMS_PER_BATCH = 50;
    /// @notice Maximum inbound amount representable at the router/provider boundary.
    uint256 public constant MAX_SUPPORTED_INBOUND_AMOUNT = type(uint128).max;
    // Opt-in refunds must leave enough gas to record credit when a receiver consumes its stipend.
    uint256 private constant REFUND_CALL_GAS = 30_000;
    using SafeERC20 for IERC20;
    using FlowGuard for FlowWindow;

    /// @notice May pause departures and tighten flow limits, and nothing else.
    /// @dev Deliberately not an admin. The point of a guardian is that you can hand the key to a
    /// monitoring job or a second person without also handing them the treasury, so every power
    /// it has is one that narrows what the bridge will do.
    bytes32 public constant GUARDIAN_ROLE = keccak256("hyperion.guardian");

    /// @notice The shortest delay an admin change can be queued for.
    /// @dev An hour is long enough that somebody watching will see a change land, and short
    /// enough that a genuine incident response is not waiting out a weekend.
    uint64 public constant MIN_TIMELOCK_DELAY = 1 hours;

    /// @notice The longest delay an admin change can be queued for.
    uint64 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @notice How long a matured action stays executable before it expires.
    /// @dev A change approved in March and executed in November is a change nobody reviewed.
    uint64 public constant override GRACE_PERIOD = 7 days;

    /// @notice Maximum length in bytes of a timelock cancellation reason note.
    uint256 public constant MAX_REASON_LEN = 128;

    /// @notice The shortest flow window a limit can be measured over, in seconds.
    uint64 public constant MIN_FLOW_WINDOW = 5 minutes;

    /// @notice The longest flow window a limit can be measured over, in seconds.
    uint64 public constant MAX_FLOW_WINDOW = 7 days;

    /// @notice Where the fee goes.
    address public treasury;

    /// @notice The fee, in basis points, charged on the outbound leg only.
    uint16 public feeBps;

    /// @notice How long a privileged change has to wait before it may be applied.
    uint64 public override timelockDelay;

    /// @notice How long a flow window runs, in seconds.
    uint64 public flowWindow;

    /// @notice This router's own counter for outbound transfers.
    uint64 public outboundNonce;

    /// @notice EIP-712 domain schema for this nonupgradeable router.
    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @notice Flat typed-intent wire schema used by development relayers.
    bytes32 public constant TRANSFER_INTENT_TYPEHASH = keccak256(
        "TransferIntent(address sender,address token,uint256 amount,uint8 route,"
        "string destinationChain,string destinationAddress,uint8 destinationDecimals,"
        "uint256 minDestinationAmount,uint256 maxProviderBudget,uint256 nonce,"
        "uint256 deadline,uint256 chainId,address router)"
    );
    /// @notice Next signed intent nonce for each authenticated sender.
    mapping(address sender => uint256 nonce) public intentNonce;

    uint64 private _claimCount;
    uint64 private _actionCount;

    mapping(RouteKind route => address adapterAddress) private _adapters;
    /// @notice Code hash captured when each adapter was activated.
    mapping(RouteKind route => bytes32 codeHash) public adapterCodeHash;
    mapping(RouteKind route => address receiver) private _railReceivers;
    /// @notice Whether a rail is open for new transfers. Deliveries already in flight are not
    /// affected, because a transfer that has left is a transfer that has to be able to land.
    mapping(RouteKind route => bool enabled) public routeEnabled;
    /// @notice Whether an individual rail is currently paused for departures.
    mapping(RouteKind route => bool paused) public routePaused;
    mapping(address token => TokenConfig config) private _tokens;

    /// @dev Keyed on token and rail together, because a ceiling that makes sense for the rail
    /// carrying native USDC makes no sense for the one carrying a pooled representation of it.
    mapping(bytes32 tokenAndRoute => uint256 limit) private _routeFlowLimit;
    mapping(bytes32 tokenAndRoute => bool isSet) private _routeFlowLimitSet;
    mapping(bytes32 tokenAndRoute => FlowWindow window) private _flow;

    /// @notice Whether a rail message has already been delivered, keyed on rail and message id.
    /// @dev Keyed on the rail's own message id at full width. Squeezing a thirty two byte
    /// identifier into something smaller to save a slot is how two unrelated messages end up
    /// sharing a replay key, and the cheaper of those two deliveries is the one an attacker picks.
    mapping(bytes32 railAndMessage => bool seen) public processed;

    /// @dev What `bridgeOut` worked out before it moved anything, carried between the three
    /// halves of it in memory rather than on the stack.
    struct OutboundPlan {
        uint256 fee;
        uint256 net;
        uint256 gross;
        address adapterAddress;
    }
    mapping(uint64 claimId => PendingClaim claim) private _claims;
    // New nonupgradeable deployments place reviewed action identity in the former record slot;
    // the immutable provenance child owns historical payload storage. No migration is performed.
    mapping(uint64 actionId => bytes32 codeHash) private _queuedAdapterCodeHash;
    OutboundProvenance private immutable OUTBOUND_PROVENANCE;
    /// @notice Latest version 1 payout reason: zero cleared, 1 refusal, 2 shortage, 3 unreadable, 4 inexact.
    mapping(uint64 claimId => uint8 reason) public claimFailureReason;
    mapping(uint64 actionId => QueuedAction queued) private _actions;
    mapping(uint64 actionId => bool cancelled) private _cancelledActions;

    /// @notice Native refunds that could not be delivered in opt-in credit mode.
    mapping(address beneficiary => uint256 amount) public refundCredits;

    ITokenRecoveryManager private immutable TOKEN_RECOVERY_MANAGER;

    /// @param admin Holds every privileged power, all of them behind the timelock.
    /// @notice Wires up the router with its roles, its treasury, and its fee and timing limits.
    /// @param admin Holds every role that can widen what the bridge will do.
    /// @param guardian_ Holds the two that only ever make the bridge do less.
    /// @param treasury_ Where the fee lands.
    /// @param feeBps_ The fee, capped at one percent by a constant no path can raise.
    /// @param timelockDelay_ How long changes wait.
    /// @param flowWindow_ How long a flow window runs, in seconds.
    constructor(
        address admin,
        address guardian_,
        address treasury_,
        uint16 feeBps_,
        uint64 timelockDelay_,
        uint64 flowWindow_
    ) {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > AmountMath.MAX_FEE_BPS) revert FeeTooHigh();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) {
            revert TimelockDelayOutOfRange();
        }
        if (flowWindow_ < MIN_FLOW_WINDOW || flowWindow_ > MAX_FLOW_WINDOW) revert InvalidWindow();

        OUTBOUND_PROVENANCE = new OutboundProvenance();
        TOKEN_RECOVERY_MANAGER = ITokenRecoveryManager(address(new TokenRecoveryManager(address(this))));
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);

        treasury = treasury_;
        feeBps = feeBps_;
        timelockDelay = timelockDelay_;
        flowWindow = flowWindow_;
        emit ConfigChanged(treasury_, feeBps_, timelockDelay_, flowWindow_);
    }
    /// @notice Accepts the native currency an adapter did not spend.
    /// @dev Adapters hand back whatever native currency the rail did not want. Without this the
    /// refund at the end of `bridgeOut` would have nothing to refund.
    receive() external payable {}

    // -------------------------------------------------------------------------------------
    // Outbound
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    /// @dev The order is fee, then floor, then hand off, and it is not interchangeable. Taking
    /// the fee on the raw amount and flooring the remainder means the sender is charged for the
    /// amount that actually crosses plus the declared fee, and nothing else. Flooring first would
    /// quietly charge a fee on dust that never left.
    ///
    /// Split across three functions because the arithmetic and the money movement do not belong
    /// in the same twenty lines, and because the EVM only lets sixteen things be reachable on the
    /// stack at once and this function wants more than that.
    function bridgeOut(OutboundRequest calldata request)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (uint64 nonce)
    {
        return _bridgeOut(request, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Try the same native refund as the legacy entrypoint, with bounded callback gas.
    /// Only a failed refund becomes credit, always owned by the caller.
    function bridgeOutWithRefundCredit(OutboundRequest calldata request)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (uint64 nonce)
    {
        return _bridgeOut(request, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    function withdrawRefundCredit(address payable recipient) external override nonReentrant {
        _withdrawRefundCredit(recipient);
    }

    function _withdrawRefundCredit(address payable recipient) private {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 amount = refundCredits[msg.sender];
        if (amount == 0) revert NoRefundCredit();
        refundCredits[msg.sender] = 0;
        (bool sent,) = recipient.call{value: amount}("");
        if (!sent) revert RefundFailed();
        emit RefundCreditWithdrawn(msg.sender, recipient, amount);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Preview before signing so the permit is bound to the exact gross debit. The preview
    /// is repeated by `_bridgeOut`, which then charges the flow window immediately before funds
    /// move. If the permit is expired, replayed, or signed for another spender or amount, the
    /// token reverts and the whole dispatch is rolled back.
    function bridgeOutWithPermit(
        OutboundRequest calldata request,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable override nonReentrant whenNotPaused returns (uint64 nonce) {
        (OutboundPlan memory plan,) = _previewOutbound(request);
        IERC20Permit(request.token).permit(msg.sender, address(this), plan.gross, deadline, v, r, s);
        return _bridgeOut(request, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    function bridgeOutBounded(OutboundRequest calldata request, uint256 maxProviderBudget)
        external
        payable
        override
        nonReentrant
        returns (uint64 nonce)
    {
        if (msg.value > maxProviderBudget) revert ProviderBudgetExceeded();
        _requireNotPaused();
        return _bridgeOut(request, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    function bridgeOutWithIntent(TransferIntent calldata intent, bytes calldata signature)
        external
        payable
        override
        nonReentrant
        returns (uint64 nonce)
    {
        return _executeSignedIntent(intent, signature, address(0), 0, false);
    }

    /// @inheritdoc IHyperionRouter
    function bridgeOutWithRelayerFee(
        TransferIntent calldata intent,
        bytes calldata signature,
        address feeToken,
        uint256 maxRelayerCharge
    ) external payable override nonReentrant returns (uint64 nonce) {
        return _executeSignedIntent(intent, signature, feeToken, maxRelayerCharge, true);
    }

    function _executeSignedIntent(
        TransferIntent calldata intent,
        bytes calldata signature,
        address feeToken,
        uint256 charge,
        bool feeSigned
    ) private returns (uint64 nonce) {
        _requireNotPaused();
        OUTBOUND_PROVENANCE.validateTransferIntent(
            intent, signature, msg.value, feeToken, charge, feeSigned, msg.sender
        );
        intentNonce[intent.sender] = intent.nonce + 1;
        OutboundRequest memory request = OutboundRequest({
            token: intent.token,
            amount: intent.amount,
            route: intent.route,
            destination: intent.destination,
            destinationDecimals: intent.destinationDecimals,
            minDestinationAmount: intent.minDestinationAmount
        });
        nonce = _bridgeOut(request, intent.sender);
        if (charge != 0) {
            IERC20 token = IERC20(feeToken);
            uint256 senderBefore = token.balanceOf(intent.sender);
            uint256 relayerBefore = token.balanceOf(msg.sender);
            // The immutable helper verified the sender's exact fee/intent signature and shared nonce;
            // both entrypoints are guarded, and the debit/credit deltas below must equal this charge.
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(intent.sender, msg.sender, charge);
            uint256 senderAfter = token.balanceOf(intent.sender);
            uint256 relayerAfter = token.balanceOf(msg.sender);
            if (
                senderAfter > senderBefore || senderBefore - senderAfter != charge
                    || relayerAfter < relayerBefore || relayerAfter - relayerBefore != charge
            ) revert InvalidRelayerFee();
            emit RelayerFeePaid(intent.sender, feeToken, msg.sender, charge);
        }
        emit TransferIntentExecuted(intent.sender, intent.nonce, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    function hashTransferIntent(TransferIntent calldata intent) public view override returns (bytes32) {
        return OUTBOUND_PROVENANCE.hashTransferIntent(intent);
    }

    /// @inheritdoc IHyperionRouter
    function hashTransferIntentWithRelayerFee(
        TransferIntent calldata intent,
        address feeToken,
        uint256 maxRelayerCharge
    ) external view override returns (bytes32) {
        return OUTBOUND_PROVENANCE.hashTransferIntentWithRelayerFee(intent, feeToken, maxRelayerCharge);
    }

    function _bridgeOut(OutboundRequest memory request, address sender) private returns (uint64 nonce) {
        OutboundPlan memory plan = _planOutbound(request);
        // The legacy wrapper retains its historical path; bounded and signed entrypoints run the
        // adapter's local validation before any token movement.
        if (request.route == RouteKind.Cctp || msg.sig != this.bridgeOut.selector) {
            _checkAdapterDispatch(request, plan);
        }

        _collectOutboundTokens(request.token, sender, plan);

        nonce = ++outboundNonce;

        uint256 balanceBefore = address(this).balance - msg.value;
        bytes32 railRef;
        if (request.route == RouteKind.AxelarIts) {
            railRef = IAxelarItsIntentAdapter(plan.adapterAddress).dispatchWithSender{value: msg.value}(
                request.token, plan.net, request.destination, nonce, sender
            );
        } else {
            railRef = IRailAdapter(plan.adapterAddress).dispatch{value: msg.value}(
                request.token, plan.net, request.destination, nonce
            );
        }

        OUTBOUND_PROVENANCE.commit(
            OutboundRecord({
                nonce: nonce,
                sender: sender,
                token: request.token,
                grossAmount: plan.gross,
                fee: plan.fee,
                netAmount: plan.net,
                route: request.route,
                adapter: plan.adapterAddress,
                destinationChain: request.destination.chain,
                destinationAddress: request.destination.strkey,
                railRef: railRef
            })
        );

        _announceOutbound(request, plan, nonce, railRef, sender);

        // Rails quote destination gas optimistically and refund the difference. Keeping it would
        // be a second, undeclared fee that moves with a gas market the sender never looked at.
        _refundNative(address(this).balance - balanceBefore, sender);
    }

    function _collectOutboundTokens(address tokenAddress, address sender, OutboundPlan memory plan) private {
        IERC20 token = IERC20(tokenAddress);
        uint256 senderBefore = token.balanceOf(sender);
        uint256 tokenBalBefore = token.balanceOf(address(this));
        token.safeTransferFrom(sender, address(this), plan.gross);
        uint256 tokenBalAfter = token.balanceOf(address(this));
        _requireExactDelta(tokenBalBefore, tokenBalAfter, plan.gross);
        uint256 senderAfter = token.balanceOf(sender);
        _requireExactDelta(senderAfter, senderBefore, plan.gross);

        if (plan.fee != 0) {
            uint256 treasuryBefore = token.balanceOf(treasury);
            token.safeTransfer(treasury, plan.fee);
            uint256 treasuryAfter = token.balanceOf(treasury);
            _requireExactDelta(treasuryBefore, treasuryAfter, plan.fee);
        }

        uint256 adapterBefore = token.balanceOf(plan.adapterAddress);
        token.safeTransfer(plan.adapterAddress, plan.net);
        uint256 adapterAfter = token.balanceOf(plan.adapterAddress);
        _requireExactDelta(adapterBefore, adapterAfter, plan.net);
        if (token.balanceOf(address(this)) != tokenBalBefore) revert InvalidAmount();
    }

    function _requireExactDelta(uint256 lowBalance, uint256 highBalance, uint256 amount) private pure {
        if (highBalance < lowBalance || highBalance - lowBalance != amount) revert InvalidAmount();
    }

    function _refundNative(uint256 amount, address sender) private {
        if (amount == 0) return;
        if (msg.sig == this.bridgeOutWithRefundCredit.selector) {
            (bool sent,) = payable(sender).call{value: amount, gas: REFUND_CALL_GAS}("");
            if (!sent) {
                refundCredits[sender] += amount;
                emit RefundCreditRecorded(sender, amount);
            }
        } else {
            (bool sent,) = payable(sender).call{value: amount}("");
            if (!sent) revert RefundFailed();
        }
    }

    /// @dev Everything that has to be true before any money moves, and the numbers that come out
    /// of it. Charges the flow limit, because a check that does not write is a check two
    /// transactions in the same block both pass.
    function _planOutbound(OutboundRequest memory request) private returns (OutboundPlan memory plan) {
        FlowWindow memory flow;
        (plan, flow) = _previewOutbound(request);
        _flow[_flowKey(request.token, request.route)] = flow;
        OUTBOUND_PROVENANCE.consumeBreaker(request.token, plan.net);
    }

    function _previewOutbound(OutboundRequest memory request)
        private
        view
        returns (OutboundPlan memory, FlowWindow memory flow)
    {
        if (
            request.route == RouteKind.Cctp
                && (request.destination.mappingRevision == 0
                    || request.destination.remoteDecimals != request.destinationDecimals)
        ) revert StaleMapping();
        (uint256 fee, uint256 net, address adapterAddress) = OUTBOUND_PROVENANCE.previewOutbound(request);

        // The flow limit is charged against what crosses, not against what the sender handed
        // over. The fee never leaves this chain, so it is not cross-chain exposure and counting
        // it would tighten the limit by a number nobody picked.
        flow = _flow[_flowKey(
                request.token, request.route
            )].consume(
            _effectiveFlowLimit(request.token, request.route), net, uint64(block.timestamp), flowWindow
        );

        return (OutboundPlan({fee: fee, net: net, gross: fee + net, adapterAddress: adapterAddress}), flow);
    }

    /// @dev The log and read-only provenance describe the same authenticated departure, carrying every field
    /// an indexer would otherwise have to reconstruct from three separate calls.
    function _announceOutbound(
        OutboundRequest memory request,
        OutboundPlan memory plan,
        uint64 nonce,
        bytes32 railRef,
        address sender
    ) private {
        emit BridgeOut(
            request.route,
            sender,
            nonce,
            request.token,
            plan.gross,
            plan.fee,
            plan.net,
            request.destination.chain,
            request.destination.strkey,
            railRef
        );
    }

    // -------------------------------------------------------------------------------------
    // Inbound
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    /// @dev Pause does not appear here, and that is deliberate. Once a rail has attested a
    /// message the counterpart is already burned on the far side, so refusing it on this side
    /// does not undo anything, it only strands somebody's money. Pausing stops departures.
    function bridgeIn(
        RouteKind route,
        address token,
        uint256 amount,
        address recipient,
        Origin calldata origin
    ) external override nonReentrant returns (uint64 claimId) {
        address expected = _railReceivers[route];
        if (expected == address(0)) revert AdapterNotSet();
        if (msg.sender != expected) revert NotRailReceiver();
        if (amount == 0) revert InvalidAmount();
        if (amount > MAX_SUPPORTED_INBOUND_AMOUNT) revert AmountNotRepresentable();
        if (recipient == address(0)) revert ZeroAddress();

        bytes32 replayKey = keccak256(abi.encode(route, origin.messageId));
        if (processed[replayKey]) revert ReplayedMessage();
        processed[replayKey] = true;

        // Pull rather than trust. The receiver approves this transfer before calling in, so if
        // the funds are not actually here the delivery reverts now instead of writing down a
        // claim against money nobody holds.
        uint256 receiverBefore = IERC20(token).balanceOf(msg.sender);
        uint256 tokenBalBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 tokenBalAfter = IERC20(token).balanceOf(address(this));
        _requireExactDelta(tokenBalBefore, tokenBalAfter, amount);
        uint256 receiverAfter = IERC20(token).balanceOf(msg.sender);
        _requireExactDelta(receiverAfter, receiverBefore, amount);

        if (_tryPay(token, recipient, amount)) {
            emit BridgeIn(route, recipient, token, amount, origin.chain, origin.nonce, origin.messageId);
            return 0;
        }

        claimId = ++_claimCount;
        _claims[claimId] = PendingClaim({
            id: claimId,
            recipient: recipient,
            token: token,
            amount: amount,
            route: route,
            sourceChain: origin.chain,
            sourceNonce: origin.nonce,
            createdAt: uint64(block.timestamp),
            settled: false
        });
        uint8 reason = _payoutFailureReason(token, amount);
        claimFailureReason[claimId] = reason;
        TOKEN_RECOVERY_MANAGER.recordClaim(token, amount);
        emit ClaimParked(claimId, recipient, token, amount, route, origin.chain, origin.nonce);
        emit ClaimPayoutFailureV1(claimId, reason, amount, recipient);
        emit BridgeIn(route, recipient, token, amount, origin.chain, origin.nonce, origin.messageId);
    }

    /// @inheritdoc IHyperionRouter
    function settleClaim(uint64 claimId) external override nonReentrant {
        this.settleClaimItem(claimId, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev A failed transfer is recorded and does not revert earlier successful payouts in
    /// this call. The recipient and amount always come from the stored claim.
    function settleClaims(uint64[] calldata claimIds)
        external
        override
        nonReentrant
        returns (ClaimSettlementResult[] memory results)
    {
        uint256 count = claimIds.length;
        if (count == 0 || count > MAX_CLAIMS_PER_BATCH) revert InvalidAmount();
        results = new ClaimSettlementResult[](count);
        for (uint256 i; i < count; ++i) {
            uint64 id = claimIds[i];
            PendingClaim storage claim = _claims[id];
            ClaimSettlementStatus status;
            if (claim.id == 0) {
                status = ClaimSettlementStatus.NotFound;
            } else if (claim.settled) {
                status = ClaimSettlementStatus.AlreadySettled;
            } else {
                try this.settleClaimItem(id, msg.sender) {
                    status = ClaimSettlementStatus.Settled;
                } catch (bytes memory failure) {
                    uint8 reason = _errorSelector(failure) == InvalidAmount.selector
                        ? 4
                        : _payoutFailureReason(claim.token, claim.amount);
                    claimFailureReason[id] = reason;
                    emit ClaimPayoutFailureV1(id, reason, claim.amount, claim.recipient);
                    status = reason == 2
                        ? ClaimSettlementStatus.InsufficientRouterBalance
                        : reason == 3
                            ? ClaimSettlementStatus.TokenUnavailable
                            : reason == 4
                                ? ClaimSettlementStatus.InvalidTokenPayout
                                : ClaimSettlementStatus.RecipientRestricted;
                }
            }
            results[i] = ClaimSettlementResult({id: id, status: status});
        }
    }

    /// @notice Atomic item call for the guarded batch; external callers cannot enter it.
    /// @param claimId The stored claim to settle.
    /// @param settler The outer batch caller, retained in the legacy settlement event.
    function settleClaimItem(uint64 claimId, address settler) external {
        if (msg.sender != address(this)) revert Unauthorized();
        PendingClaim storage claim = _claims[claimId];
        if (claim.id == 0) revert ClaimNotFound();
        if (claim.settled) revert ClaimAlreadySettled();
        claim.settled = true;
        if (!_tryPay(claim.token, claim.recipient, claim.amount)) revert RecipientNotReady();
        TOKEN_RECOVERY_MANAGER.releaseClaim(claim.token, claim.amount);
        delete claimFailureReason[claimId];
        emit ClaimSettled(claimId, claim.recipient, claim.token, claim.amount, settler);
    }

    /// @inheritdoc IHyperionRouter
    function completeTokenRecovery(address tokenAddress, address recipient, uint256 amount)
        external
        override
        nonReentrant
    {
        if (msg.sender != address(TOKEN_RECOVERY_MANAGER)) revert Unauthorized();
        IERC20(tokenAddress).safeTransfer(recipient, amount);
    }

    /// @dev V1: 1 refusal, 2 shortage, 3 unreadable token, 4 inexact token payout.
    function _payoutFailureReason(address token, uint256 amount) private view returns (uint8) {
        try IERC20(token).balanceOf(address(this)) returns (uint256 balance) {
            return balance < amount ? 2 : 1;
        } catch {
            return 3;
        }
    }

    /// @inheritdoc IHyperionRouter
    function explainOutbound(
        OutboundRequest calldata request,
        uint256 providerPayment,
        uint256 maxProviderBudget
    ) external view override returns (bytes4 blocker) {
        try this.checkOutbound(request, providerPayment, maxProviderBudget) {
            return bytes4(0);
        } catch (bytes memory failure) {
            return _errorSelector(failure);
        }
    }

    /// @notice Validate bounded dispatch locally without moving funds.
    /// @param request The legacy outbound request.
    /// @param providerPayment Prospective native payment in wei.
    /// @param maxProviderBudget Maximum native payment in wei.
    function checkOutbound(
        OutboundRequest calldata request,
        uint256 providerPayment,
        uint256 maxProviderBudget
    ) external view {
        if (providerPayment > maxProviderBudget) revert ProviderBudgetExceeded();
        _requireNotPaused();
        (OutboundPlan memory plan,) = _previewOutbound(request);
        _checkAdapterDispatch(request, plan);
    }

    function _checkAdapterDispatch(OutboundRequest memory request, OutboundPlan memory plan) private view {
        try IRailAdapter(plan.adapterAddress).checkDispatch(request.token, plan.net, request.destination) {}
        catch (bytes memory failure) {
            OUTBOUND_PROVENANCE.rethrowAdapterFailure(failure);
        }
    }

    function _errorSelector(bytes memory failure) private pure returns (bytes4) {
        if (failure.length < 4) return AdapterMethodUnavailable.selector;
        // The length guard above proves this deliberate selector-prefix extraction is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(failure);
    }

    // -------------------------------------------------------------------------------------
    // Quoting
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    function quote(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) public view override returns (RouteQuote memory) {
        return OUTBOUND_PROVENANCE.quote(route, token, amount, destination, destinationDecimals);
    }

    /// @inheritdoc IHyperionRouter
    function quoteV2(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view override returns (RouteQuoteV2 memory v) {
        (bool ok, bytes memory result) = address(OUTBOUND_PROVENANCE)
            .staticcall(
                abi.encodeCall(
                    OutboundProvenance.quoteV2, (route, token, amount, destination, destinationDecimals)
                )
            );
        assembly ("memory-safe") {
            pop(v)
            if iszero(ok) { revert(add(result, 32), mload(result)) }
            return(add(result, 32), mload(result))
        }
    }

    /// @inheritdoc IHyperionRouter
    function quoteAll(
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view override returns (RouteQuote[] memory quotes) {
        (bool ok, bytes memory result) = address(OUTBOUND_PROVENANCE)
            .staticcall(
                abi.encodeCall(OutboundProvenance.quoteAll, (token, amount, destination, destinationDecimals))
            );
        assembly ("memory-safe") {
            pop(quotes)
            if iszero(ok) { revert(add(result, 32), mload(result)) }
            return(add(result, 32), mload(result))
        }
    }

    /// @notice Take a Stellar address apart and say whether it holds together.
    /// @dev External so `quote` can reach it inside a try, and public because an app that can ask
    /// this over `eth_call` never has to ship its own base32 decoder and hope it agrees with this
    /// one. Reverts on anything it does not like, which is the point.
    function checkDestination(string calldata strkey)
        external
        view
        returns (AddressKind kind, bytes32 key, uint64 muxedId)
    {
        (bool ok, bytes memory result) = address(OUTBOUND_PROVENANCE)
            .staticcall(abi.encodeCall(OutboundProvenance.checkDestination, (strkey)));
        assembly ("memory-safe") {
            pop(kind)
            pop(key)
            pop(muxedId)
            if iszero(ok) { revert(add(result, 32), mload(result)) }
            return(add(result, 32), mload(result))
        }
    }

    // -------------------------------------------------------------------------------------
    // The two powers that do not wait
    // -------------------------------------------------------------------------------------

    /// @notice Stop new departures.
    /// @dev Guardian or admin. Arrivals keep working, because the money for those is already
    /// committed elsewhere.
    function pause() external {
        _requireGuardianOrAdmin();
        _pause();
    }

    /// @notice Start them again.
    /// @dev Admin only. Stopping should be easy and starting again should not, because one of
    /// those two decisions is reversible and the other is the one that gets made at four in the
    /// morning by somebody who wants the alert to go away.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Guardian or admin. Other rails and arrivals keep working.
    function pauseRoute(RouteKind route) external {
        _requireGuardianOrAdmin();
        routePaused[route] = true;
        emit RoutePaused(route, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Guardian or admin.
    function unpauseRoute(RouteKind route) external {
        _requireGuardianOrAdmin();
        routePaused[route] = false;
        emit RouteUnpaused(route, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev No timelock, because it only ever narrows. Raising one is a queued action.
    function lowerTokenFlowLimit(address token, uint256 limit) external override {
        _requireGuardianOrAdmin();
        TokenConfig storage cfg = _tokens[token];
        if (!cfg.registered) revert TokenNotRegistered();
        if (limit >= cfg.flowLimit) revert LimitNotRaised();
        cfg.flowLimit = limit;
        emit FlowLimitLowered(token, msg.sender, limit);
        emit TokenRegistered(token, cfg);
    }

    /// @inheritdoc IHyperionRouter
    function circuitBreaker(address token) external view override returns (uint256, bool) {
        return OUTBOUND_PROVENANCE.circuitBreaker(token);
    }

    // -------------------------------------------------------------------------------------
    // Everything else, on a clock
    // -------------------------------------------------------------------------------------

    // Proposal generation is deliberately Stellar-only for now: script/stellar/propose.sh refuses
    // manifests whose family is not "stellar" and emits the Soroban variant names. Nothing here
    // assumes an EVM counterpart has been validated, and no tool queues these actions on EVM.
    /// @inheritdoc IHyperionRouter
    function queueAction(AdminAction calldata action)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint64 id)
    {
        _validateAction(action);
        id = ++_actionCount;
        uint64 eta = uint64(block.timestamp) + timelockDelay;
        uint64 expiresAt = eta + GRACE_PERIOD;
        _actions[id] = QueuedAction({
            id: id,
            action: action,
            queuedAt: uint64(block.timestamp),
            eta: eta,
            expiresAt: expiresAt,
            executed: false
        });
        if (action.kind == ActionKind.SetAdapter) _queuedAdapterCodeHash[id] = action.subject.codehash;
        emit ActionQueued(id, action.kind, eta, expiresAt);
        emit ActionAuditUpdated(1, id, ActionAuditStatus.Queued, msg.sender, CancelReason.Unspecified, "");
    }

    /// @inheritdoc IHyperionRouter
    function executeAction(uint64 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        QueuedAction storage queued = _actions[id];
        if (queued.id == 0 || _cancelledActions[id]) revert TimelockNotQueued();
        if (queued.executed) revert TimelockAlreadyExecuted();
        if (block.timestamp < queued.eta) revert TimelockNotReady(queued.eta);
        if (block.timestamp > queued.expiresAt) revert TimelockExpired(queued.expiresAt);

        queued.executed = true;
        AdminAction memory action = queued.action;
        // Re-checked on the way out as well as the way in. The bounds a change was measured
        // against can move while it waits, and an action queued under one ceiling should not land
        // under another.
        _validateAction(action);
        if (action.kind == ActionKind.SetAdapter && action.subject.codehash != _queuedAdapterCodeHash[id]) {
            revert AdapterIdentityMismatch();
        }
        _applyAction(action);
        emit ActionExecuted(id, action.kind);
        emit ActionAuditUpdated(1, id, ActionAuditStatus.Executed, msg.sender, CancelReason.Unspecified, "");
    }

    /// @inheritdoc IHyperionRouter
    function cancelActionWithReason(uint64 id, CancelReason reason, string calldata note) external override {
        _cancelAction(id, reason, note);
    }

    function _requireGuardianOrAdmin() private view {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
    }

    function _cancelAction(uint64 id, CancelReason reason, string memory note) private {
        _requireGuardianOrAdmin();
        bytes memory raw = bytes(note);
        if (raw.length > MAX_REASON_LEN) revert InvalidLimit();
        for (uint256 i; i < raw.length; ++i) {
            if (uint8(raw[i]) < 32 || uint8(raw[i]) > 126) revert InvalidLimit();
        }
        QueuedAction storage queued = _actions[id];
        if (queued.id == 0 || _cancelledActions[id]) revert TimelockNotQueued();
        if (queued.executed) revert TimelockAlreadyExecuted();
        _cancelledActions[id] = true;
        // Retain the canonical payload and schedule. The audit status blocks execution forever.
        emit ActionCancelled(id, msg.sender);
        emit ActionAuditUpdated(1, id, ActionAuditStatus.Cancelled, msg.sender, reason, note);
    }

    /// @notice Role changes go through the timelock like everything else.
    /// @dev Overridden to revert, because inheriting `AccessControl` as it comes would leave an
    /// admin able to grant a second admin in one transaction and make the timelock decorative.
    function grantRole(bytes32, address) public pure override {
        revert Unauthorized();
    }

    /// @notice Role changes go through the timelock like everything else.
    function revokeRole(bytes32, address) public pure override {
        revert Unauthorized();
    }

    // -------------------------------------------------------------------------------------
    // Reading
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    function queuedAction(uint64 id) external view override returns (QueuedAction memory) {
        return _actions[id];
    }

    /// @inheritdoc IHyperionRouter
    function actionCancelled(uint64 id) external view override returns (bool) {
        return _cancelledActions[id];
    }

    /// @inheritdoc IHyperionRouter
    function pendingClaim(uint64 id) external view override returns (PendingClaim memory) {
        return _claims[id];
    }

    /// @inheritdoc IHyperionRouter
    function tokenConfig(address token) external view override returns (TokenConfig memory) {
        return _tokens[token];
    }

    /// @inheritdoc IHyperionRouter
    function outboundRecord(uint64 nonce) external view override returns (OutboundRecord memory record) {
        (bool ok, bytes memory result) = address(OUTBOUND_PROVENANCE)
            .staticcall(abi.encodeCall(OutboundProvenance.outboundRecord, (nonce)));
        assembly ("memory-safe") {
            pop(record)
            if iszero(ok) { revert(add(result, 32), mload(result)) }
            return(add(result, 32), mload(result))
        }
    }

    /// @inheritdoc IHyperionRouter
    function flowAvailable(address token, RouteKind route) public view override returns (uint256) {
        bytes32 key = _flowKey(token, route);
        return _flow[key].available(_effectiveFlowLimit(token, route), uint64(block.timestamp), flowWindow);
    }

    /// @notice How many claims have been parked since deployment.
    function claimCount() external view returns (uint64) {
        return _claimCount;
    }

    /// @notice How many privileged changes have been queued since deployment.
    function actionCount() external view returns (uint64) {
        return _actionCount;
    }

    /// @inheritdoc IHyperionRouter
    function adapter(RouteKind route) external view override returns (address) {
        return _adapters[route];
    }

    /// @notice The contract allowed to call `bridgeIn` for a rail.
    function railReceiver(RouteKind route) external view returns (address) {
        return _railReceivers[route];
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    function _flowKey(address token, RouteKind route) private pure returns (bytes32) {
        return keccak256(abi.encode(token, route));
    }

    function _effectiveFlowLimit(address token, RouteKind route) private view returns (uint256) {
        bytes32 key = _flowKey(token, route);
        if (_routeFlowLimitSet[key]) return _routeFlowLimit[key];
        return _tokens[token].flowLimit;
    }

    /// @dev Pay out without letting a refusal take the whole delivery down with it.
    ///
    /// A token can decline a transfer for reasons that have nothing to do with Hyperion: USDC
    /// freezes accounts, and a frozen recipient must not be able to wedge a message the rail has
    /// already attested. So the result is a boolean and the caller decides what to do with it.
    ///
    /// A successful token call is insufficient: both balances must change by exactly the
    /// promised amount. A refusal may park a claim only if it leaves both balances unchanged.
    function _tryPay(address token, address to, uint256 amount) private returns (bool) {
        IERC20 asset = IERC20(token);
        uint256 fromBefore = asset.balanceOf(address(this));
        uint256 toBefore = asset.balanceOf(to);
        bool delivered = asset.trySafeTransfer(to, amount);
        uint256 fromAfter = asset.balanceOf(address(this));
        uint256 toAfter = asset.balanceOf(to);
        if (delivered) {
            _requireExactDelta(fromAfter, fromBefore, amount);
            _requireExactDelta(toBefore, toAfter, amount);
        } else if (fromAfter != fromBefore || toAfter != toBefore) {
            revert InvalidAmount();
        }
        return delivered;
    }

    /// @dev Every field a kind does not use has to be empty.
    ///
    /// A timelock only does its job if somebody can read a pending change and understand it. A
    /// struct with a spare field carrying a value nothing validates is a change that reads one
    /// way to a reviewer and another way to the code, so the unused fields are checked rather
    /// than ignored. `RouteKind` has no unset value, so `Cctp` doubles as one where a kind has
    /// nothing to do with a rail.
    function _validateAction(AdminAction memory action) private view {
        OUTBOUND_PROVENANCE.validate(action);
    }

    function _applyAction(AdminAction memory action) private {
        ActionKind kind = action.kind;
        if (kind >= ActionKind.SetTokenCircuitBreakerThreshold) {
            OUTBOUND_PROVENANCE.configureBreaker(action);
            return;
        }
        if (kind == ActionKind.SetFeeBps) {
            feeBps = uint16(action.amount);
        } else if (kind == ActionKind.SetTreasury) {
            treasury = action.subject;
        } else if (kind == ActionKind.SetAdmin) {
            _grantRole(DEFAULT_ADMIN_ROLE, action.subject);
        } else if (kind == ActionKind.SetGuardian) {
            _grantRole(GUARDIAN_ROLE, action.subject);
        } else if (kind == ActionKind.SetAdapter) {
            _adapters[action.route] = action.subject;
            adapterCodeHash[action.route] = action.subject.codehash;
            emit AdapterSet(action.route, action.subject);
            emit AdapterIdentityRecorded(action.route, action.subject, action.subject.codehash);
        } else if (kind == ActionKind.SetRailReceiver) {
            _railReceivers[action.route] = action.subject;
            emit RailReceiverSet(action.route, action.subject);
        } else if (kind == ActionKind.EnableRoute) {
            bool on = action.amount == 1;
            routeEnabled[action.route] = on;
            emit RouteConfigured(action.route, on);
            return;
        } else if (
            kind == ActionKind.RegisterToken || kind == ActionKind.RaiseTokenFlowLimit
                || kind == ActionKind.SetTokenEnabled
        ) {
            TokenConfig storage cfg = _tokens[action.subject];
            if (kind == ActionKind.RegisterToken) {
                cfg.registered = true;
                cfg.enabled = true;
                cfg.decimals = action.decimals;
                cfg.flowLimit = action.amount;
            } else if (kind == ActionKind.RaiseTokenFlowLimit) {
                cfg.flowLimit = action.amount;
            } else {
                cfg.enabled = action.amount == 1;
            }
            emit TokenRegistered(action.subject, cfg);
            return;
        } else if (kind == ActionKind.SetRouteFlowLimit) {
            bytes32 key = _flowKey(action.subject, action.route);
            _routeFlowLimit[key] = action.amount;
            _routeFlowLimitSet[key] = true;
            return;
        } else if (kind == ActionKind.SetTimelockDelay) {
            timelockDelay = uint64(action.amount);
        } else {
            flowWindow = uint64(action.amount);
        }
        emit ConfigChanged(treasury, feeBps, timelockDelay, flowWindow);
    }
}
