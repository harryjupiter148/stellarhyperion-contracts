// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ActionAuditStatus,
    ActionKind,
    AdminAction,
    CancelReason,
    ClaimSettlementResult,
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
} from "../HyperionTypes.sol";

/// @title The router, as everything outside it sees it
/// @notice Two entry points carry every transfer. `bridgeOut` is what a person calls, and
/// `bridgeIn` is what a rail's own receiving contract calls once its verifier has already decided
/// the message is real. Hyperion never decides that itself, on either chain, which is the single
/// design decision the rest of this repository is downstream of.
///
/// Everything else here is either a question you can ask before committing money, or an admin
/// action that has to sit in a timelock first.
interface IHyperionRouter {
    /// @notice An authenticated sender intent executed through a development relayer.
    /// @param sender The signer whose tokens were debited.
    /// @param intentNonce The consumed sender intent nonce.
    /// @param relayer The transaction submitter.
    event TransferIntentExecuted(
        address indexed sender, uint256 indexed intentNonce, address indexed relayer
    );

    /// @notice A transfer left for another chain.
    /// @dev The Soroban router writes a `TransferRecord` to storage as well as emitting, because
    /// Soroban events age out after about a week and an indexer that fell behind has nowhere else
    /// to look. A log on this chain is permanent, so this is the only record and that is enough.
    /// @param route Which rail carried it.
    /// @param sender Who paid.
    /// @param nonce This router's counter for the transfer, and what the far side reads back.
    /// @param token The ERC20 that left.
    /// @param grossAmount What the sender was charged, which is the fee plus the net and can be
    /// less than the amount they asked to send when flooring gave them dust back.
    /// @param fee What Hyperion kept.
    /// @param netAmount What went onto the rail.
    /// @param destinationChain Hyperion's name for where it is headed.
    /// @param destinationAddress The recipient's strkey, as a string, so an indexer never has to
    /// re-encode one to show it.
    /// @param railRef Whatever the rail calls this transfer, or zero if it names it nothing.
    event BridgeOut(
        RouteKind indexed route,
        address indexed sender,
        uint64 indexed nonce,
        address token,
        uint256 grossAmount,
        uint256 fee,
        uint256 netAmount,
        string destinationChain,
        string destinationAddress,
        bytes32 railRef
    );

    /// @notice A transfer arrived and was paid straight through.
    /// @param route Which rail delivered it.
    /// @param recipient Who was paid.
    /// @param token The ERC20 they were paid in.
    /// @param amount How much landed.
    /// @param sourceChain Hyperion's name for where it came from.
    /// @param sourceNonce The far side's counter, which is what joins this to its departure.
    /// @param messageId The rail's own identifier, and the replay key.
    event BridgeIn(
        RouteKind indexed route,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        string sourceChain,
        uint64 sourceNonce,
        bytes32 messageId
    );

    /// @notice A transfer arrived and could not be paid out yet, so the router is holding it.
    /// @dev The money is here and it is theirs. Emitted rather than reverted, because reverting
    /// would send the message back to a rail that has already burned the tokens on the far side.
    /// @param id The claim's id, which is what `settleClaim` takes.
    /// @param recipient Who the money belongs to.
    /// @param token The ERC20 being held.
    /// @param amount How much is being held.
    /// @param route Which rail delivered it.
    /// @param sourceChain Hyperion's name for where it came from.
    /// @param sourceNonce The far side's counter for the departure.
    event ClaimParked(
        uint64 indexed id,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        RouteKind route,
        string sourceChain,
        uint64 sourceNonce
    );

    /// @notice A parked transfer was paid out.
    /// @dev `settledBy` is whoever pressed the button, which does not have to be the recipient.
    /// Anybody can settle somebody else's claim; the money only ever goes to the recipient, so
    /// there is nothing to gain by it and someone watching for stuck transfers can just clear
    /// them.
    /// @param id The claim that was cleared.
    /// @param recipient Who was paid.
    /// @param token The ERC20 they were paid in.
    /// @param amount How much they were paid.
    /// @param settledBy Whoever sent the transaction.
    event ClaimSettled(
        uint64 indexed id, address indexed recipient, address token, uint256 amount, address settledBy
    );

    /// @notice Version 1 diagnostic for a claim payout that remains outstanding.
    /// @dev The claim amount and fixed recipient remain in `pendingClaim`; this event adds only
    /// the bounded reason so existing claim/indexing records remain valid.
    /// @param id The parked claim ID.
    /// @param reason Version 1 refusal, shortage, unreadable-token or inexact-payout code.
    /// @param outstandingAmount The full amount still owed to the recorded recipient.
    /// @param recipient The recorded payout recipient.
    event ClaimPayoutFailureV1(uint64 indexed id, uint8 reason, uint256 outstandingAmount, address recipient);

    /// @notice A privileged change was proposed, and the clock started.
    /// @param id The action's id.
    /// @param kind What sort of change it is.
    /// @param eta The earliest timestamp it can be executed at.
    /// @param expiresAt When it stops being executable and has to be queued again.
    event ActionQueued(uint64 indexed id, ActionKind indexed kind, uint64 eta, uint64 expiresAt);

    /// @notice A privileged change waited out its delay and took effect.
    /// @param id The action that was applied.
    /// @param kind What sort of change it was.
    event ActionExecuted(uint64 indexed id, ActionKind indexed kind);

    /// @notice A queued change was dropped before it took effect.
    /// @param id The action that was dropped.
    /// @param by Who dropped it.
    event ActionCancelled(uint64 indexed id, address indexed by);

    /// @notice Emitted on queue, execute, and cancel with bounded audit metadata.
    /// @param version Audit encoding version, currently one.
    /// @param id The original action identifier.
    /// @param status The lifecycle transition.
    /// @param actor The caller responsible for this transition.
    /// @param cancelReason Structured cancellation reason, or Unspecified.
    /// @param reasonNote At most 128 printable ASCII bytes.
    event ActionAuditUpdated(
        uint32 version,
        uint64 indexed id,
        ActionAuditStatus indexed status,
        address indexed actor,
        CancelReason cancelReason,
        string reasonNote
    );

    /// @notice A token's flow limit was tightened without waiting.
    /// @dev Allowed to skip the timelock precisely because it only ever narrows what the bridge
    /// will do. Raising one is a queued action; lowering one is something you want available at
    /// three in the morning.
    /// @param token The token whose ceiling moved.
    /// @param by Who moved it.
    /// @param limit The new ceiling, which is always lower than the old one.
    event FlowLimitLowered(address indexed token, address indexed by, uint256 limit);

    /// @notice A token's emergency breaker latched and new departures for it are refused.
    /// @dev The departure that reaches the threshold completes and then latches the breaker; a
    /// departure that would cross it is refused before any funds move.
    /// @param token The token that is now stopped for departures.
    /// @param observedAmount The rolling amount counted when the breaker latched.
    /// @param threshold The ceiling in force.
    event CircuitBreakerTripped(address indexed token, uint256 observedAmount, uint256 threshold);

    /// @notice A token became routable, or its parameters changed.
    /// @param token The ERC20.
    /// @param config Its decimals, its ceiling, and whether it is currently enabled.
    event TokenRegistered(address indexed token, TokenConfig config);

    /// @notice A rail was turned on or off for everybody.
    /// @param route The rail.
    /// @param enabled Whether it now accepts departures. Arrivals are never affected.
    event RouteConfigured(RouteKind indexed route, bool enabled);

    /// @notice A rail was paused individually.
    /// @param route Which rail was paused.
    /// @param caller Who paused it.
    event RoutePaused(RouteKind indexed route, address indexed caller);

    /// @notice A rail was unpaused individually.
    /// @param route Which rail was unpaused.
    /// @param caller Who unpaused it.
    event RouteUnpaused(RouteKind indexed route, address indexed caller);

    /// @notice The adapter that speaks for a rail was pointed somewhere else.
    /// @param route The rail.
    /// @param adapter Its new adapter, or zero when the rail was unwired.
    event AdapterSet(RouteKind indexed route, address indexed adapter);

    /// @notice Records the deployed adapter code identity accepted at activation time.
    /// @param route The rail accepting the adapter.
    /// @param adapter The router-bound adapter.
    /// @param codeHash The reviewed runtime hash.
    event AdapterIdentityRecorded(RouteKind indexed route, address indexed adapter, bytes32 codeHash);

    /// @notice The contract allowed to call `bridgeIn` for a rail was changed.
    /// @param route The rail.
    /// @param receiver The only address that rail's arrivals may come from.
    event RailReceiverSet(RouteKind indexed route, address indexed receiver);

    /// @notice Where the fee goes, or how much of it there is, changed.
    /// @param treasury Where the fee lands.
    /// @param feeBps The fee in basis points, capped at one percent by a constant.
    /// @param timelockDelay How long a queued change now waits, in seconds.
    /// @param flowWindow How long a flow window now runs, in seconds.
    event ConfigChanged(address treasury, uint16 feeBps, uint64 timelockDelay, uint64 flowWindow);

    /// @notice A native refund could not be delivered and was recorded for the sender.
    /// @param beneficiary The caller whose direct native refund failed.
    /// @param amount The retained native remainder.
    event RefundCreditRecorded(address indexed beneficiary, uint256 amount);

    /// @notice The beneficiary withdrew their native refund credit to their selected recipient.
    /// @param beneficiary The original credit owner authorizing withdrawal.
    /// @param recipient The native-currency recipient selected by that owner.
    /// @param amount The credit paid out.
    event RefundCreditWithdrawn(address indexed beneficiary, address indexed recipient, uint256 amount);

    /// @notice Dispatch while recording an undeliverable native refund for the sender.
    /// @dev This is opt-in. `bridgeOut` retains its legacy reverting-refund behavior.
    /// @param request The unchanged token, amount, rail, destination, and slippage intent.
    /// @return nonce The outbound nonce.
    function bridgeOutWithRefundCredit(OutboundRequest calldata request)
        external
        payable
        returns (uint64 nonce);

    /// @notice Withdraw the caller's previously recorded native refund credit.
    /// @notice Withdraw the caller's credit to a recipient they authorize.
    /// @dev Enables recovery for beneficiaries whose own receive function always rejects native currency.
    /// A failed delivery reverts and preserves the caller's credit.
    /// @param recipient A nonzero native-currency recipient selected by the original beneficiary.
    function withdrawRefundCredit(address payable recipient) external;

    /// @notice Send `request.amount` of a token to another chain.
    /// @dev Pull, then fee, then floor, then hand off. The fee comes off the raw amount and the
    /// remainder is floored to what the destination can actually represent, in that order, so the
    /// number somebody is quoted is the number that arrives.
    ///
    /// Payable because some rails bill for destination gas at send time. Anything left over is
    /// refunded in the same transaction.
    /// @param request The token, the amount, the rail, the destination, and the least the sender
    /// is willing to see land on the far side.
    /// @return nonce This router's own counter for the transfer, which is also what appears in the
    /// note the far side reads.
    function bridgeOut(OutboundRequest calldata request) external payable returns (uint64 nonce);

    /// @notice Approve exactly this transfer with EIP-2612, then dispatch it.
    /// @dev The permit value is the router's calculated gross debit (net amount plus fee),
    /// never an allowance chosen by the caller. Tokens without EIP-2612 keep using `bridgeOut`
    /// after an explicit approval.
    /// @param request The token, amount, rail, destination, and slippage floor.
    /// @param deadline The permit deadline enforced by the token.
    /// @param v The ECDSA recovery byte for the permit signature.
    /// @param r The first ECDSA signature word.
    /// @param s The second ECDSA signature word.
    /// @return nonce The outbound nonce.
    function bridgeOutWithPermit(
        OutboundRequest calldata request,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint64 nonce);

    /// @notice Read the provenance committed for a successful outbound dispatch.
    /// @dev A missing nonce returns a zero-valued record. Reverted dispatches never create one.
    /// @param nonce The successful source dispatch nonce.
    /// @return record Exact committed intent and provider metadata, or a zero-valued record.
    function outboundRecord(uint64 nonce) external view returns (OutboundRecord memory record);

    /// @notice Pay out a transfer that arrived over a rail.
    /// @dev Callable only by the contract registered as that rail's receiver, and only after the
    /// rail's own verifier has accepted the message. Hyperion adds a replay guard on top of that
    /// and nothing else: the question of whether the message is genuine was already answered by
    /// somebody with an audit.
    ///
    /// No flow ceiling on this side, deliberately. A limit works by refusing, and refusing an
    /// arrival cannot undo the burn that paid for it, so all a ceiling here would do is strand
    /// somebody's money until an admin raised it. Ceilings belong on departures, where the funds
    /// are still in the sender's wallet and a refusal costs nobody anything.
    /// @param route Which rail this arrival came over.
    /// @param token The ERC20 to pay out.
    /// @param amount How much to pay out, in this chain's decimals for the token.
    /// @param recipient Who to pay.
    /// @param origin The source chain, the far side's nonce, and the rail's message id.
    /// @return claimId Zero when the recipient was paid, or the id of a parked claim when they
    /// could not be.
    function bridgeIn(
        RouteKind route,
        address token,
        uint256 amount,
        address recipient,
        Origin calldata origin
    ) external returns (uint64 claimId);

    /// @notice Pay out a claim the router has been holding.
    /// @dev Permissionless. The funds go to the claim's recipient no matter who calls.
    /// @param claimId The claim to clear.
    function settleClaim(uint64 claimId) external;

    /// @notice Attempt a bounded set of claims independently, returning one outcome per input.
    /// @param claimIds At most 50 stored claim IDs, including duplicates if desired.
    /// @return results Confirmed outcome for each input ID, in input order.
    function settleClaims(uint64[] calldata claimIds)
        external
        returns (ClaimSettlementResult[] memory results);

    /// @notice Complete the exact transfer authorized by the router-owned recovery manager.
    /// @dev Only the manager deployed at router CREATE nonce 2 may call this guarded hook.
    /// @param token The unregistered ERC20 whose surplus is authorized for recovery.
    /// @param recipient The fixed recipient authorized by the queued recovery.
    /// @param amount The exact amount to transfer in token base units.
    function completeTokenRecovery(address token, address recipient, uint256 amount) external;

    /// @notice Dispatch with a native provider cap while preserving legacy request fields.
    /// @param request The legacy outbound request.
    /// @param maxProviderBudget Maximum msg.value passed to the provider, in native-currency wei.
    /// @return nonce The outbound nonce.
    function bridgeOutBounded(OutboundRequest calldata request, uint256 maxProviderBudget)
        external
        payable
        returns (uint64 nonce);

    /// @notice Dispatch one sender-signed intent within its declared provider budget.
    /// @param intent The complete chain/router-bound sender authorization.
    /// @param signature The canonical 65-byte ECDSA signature.
    /// @return nonce The source dispatch nonce committed on success.
    function bridgeOutWithIntent(TransferIntent calldata intent, bytes calldata signature)
        external
        payable
        returns (uint64 nonce);

    /// @notice The next available signed-intent nonce for a sender.
    /// @param sender The authenticated token owner.
    /// @return The next nonce, consumed only by successful execution.
    function intentNonce(address sender) external view returns (uint256);

    /// @notice Compute the exact EIP-712 sender authorization digest.
    /// @param intent The complete typed transfer intent.
    /// @return The chain/router-bound digest.
    function hashTransferIntent(TransferIntent calldata intent) external view returns (bytes32);

    /// @notice Execute an intent with a separately signed exact relayer fee cap.
    /// @dev The signature covers the legacy intent digest, fee token and charge.
    /// @param intent The outbound intent sharing the sender's legacy nonce.
    /// @param signature The sender's signature over the transfer digest, fee asset and charge.
    /// @param feeToken The signed enabled ERC-20 fee asset, or zero for no charge.
    /// @param maxRelayerCharge The signed exact charge paid on successful dispatch.
    /// @return nonce The successful outbound dispatch nonce.
    function bridgeOutWithRelayerFee(
        TransferIntent calldata intent,
        bytes calldata signature,
        address feeToken,
        uint256 maxRelayerCharge
    ) external payable returns (uint64 nonce);

    /// @notice Hash a fee-bearing intent in this router's EIP-712 domain.
    /// @param intent The immutable outbound transfer authorization.
    /// @param feeToken The signed fee asset.
    /// @param maxRelayerCharge The signed exact relayer charge.
    function hashTransferIntentWithRelayerFee(
        TransferIntent calldata intent,
        address feeToken,
        uint256 maxRelayerCharge
    ) external view returns (bytes32);

    /// @notice The signed fee was paid after successful dispatch, in the same atomic transaction.
    /// @param sender The sender who authorized and paid the charge.
    /// @param feeToken The ERC-20 asset used for the charge.
    /// @param relayer The executing relayer receiving the charge.
    /// @param amount The exact signed charge.
    event RelayerFeePaid(
        address indexed sender, address indexed feeToken, address indexed relayer, uint256 amount
    );

    /// @notice Return zero for passing local bounded checks, otherwise the earliest error selector.
    /// @param request The legacy outbound request.
    /// @param providerPayment Prospective native payment in wei.
    /// @param maxProviderBudget Maximum native payment in wei.
    /// @return blocker Zero or the earliest error selector; provider execution still needs simulation.
    function explainOutbound(
        OutboundRequest calldata request,
        uint256 providerPayment,
        uint256 maxProviderBudget
    ) external view returns (bytes4 blocker);

    /// @notice What a transfer would cost and whether it would go through, without sending it.
    /// @dev Never reverts for a blocked route. It returns a reason instead, because the app has
    /// to explain the blockage to somebody, and a bare revert gives it nothing to say.
    /// @param route Which rail to price.
    /// @param token The ERC20 being sent.
    /// @param amount The gross amount the sender has in mind.
    /// @param destination Chain name plus the recipient's strkey.
    /// @param destinationDecimals How many decimals the token has on the far side, which the
    /// caller supplies because this chain has no way to read another chain's token.
    /// @return The fee, the net, what lands, the current headroom, and a reason if it is blocked.
    function quote(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view returns (RouteQuote memory);

    /// @notice Every route's answer for the same transfer, for the side by side view.
    /// @param token The ERC20 being sent.
    /// @param amount The gross amount the sender has in mind.
    /// @param destination Chain name plus the recipient's strkey.
    /// @param destinationDecimals How many decimals the token has on the far side.
    /// @return One quote per rail, in `RouteKind` order, so the index is the route.
    function quoteAll(
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view returns (RouteQuote[] memory);

    /// @notice Propose a privileged change and start its clock.
    /// @param action What to change, and to what.
    /// @return id The action's id, which `executeAction` and `cancelAction` take.
    function queueAction(AdminAction calldata action) external returns (uint64 id);

    /// @notice Apply a proposed change that has waited long enough and has not expired.
    /// @param id The action to apply.
    function executeAction(uint64 id) external;

    /// @notice Current delay applied to new router governance and recovery proposals.
    function timelockDelay() external view returns (uint64);

    /// @notice Execution grace period after a queued action matures.
    function GRACE_PERIOD() external view returns (uint64);

    /// @notice Drop a proposed change.
    /// @param id The action to drop.
    /// @notice Drop a proposed change with a structured reason code and bounded audit note.
    /// @param id The action to drop.
    /// @param reason Structured cancellation reason.
    /// @param note Bounded human-readable audit note (max 128 bytes).
    function cancelActionWithReason(uint64 id, CancelReason reason, string calldata note) external;

    /// @notice Tighten a token's flow limit immediately.
    /// @param token The token to tighten.
    /// @param limit The new ceiling, which has to be below the one in force.
    function lowerTokenFlowLimit(address token, uint256 limit) external;

    /// @notice Read a token's emergency breaker threshold and latch state.
    /// @param token The token to read.
    /// @return threshold The token-wide rolling ceiling, or zero when no breaker is configured.
    /// @return tripped Whether departures for this token are currently refused by the breaker.
    function circuitBreaker(address token) external view returns (uint256 threshold, bool tripped);

    /// @notice Pause departures for a single rail without affecting other rails.
    /// @param route The rail to pause.
    function pauseRoute(RouteKind route) external;

    /// @notice Resume departures for an individually paused rail.
    /// @param route The rail to unpause.
    function unpauseRoute(RouteKind route) external;

    /// @notice Read a queued change.
    /// @param id The action to read.
    /// @return The action, its timestamps, and whether it has already been executed.
    function queuedAction(uint64 id) external view returns (QueuedAction memory);

    /// @notice Whether the action was cancelled; its original payload remains queryable.
    /// @param id The action to read.
    function actionCancelled(uint64 id) external view returns (bool);

    /// @notice Read a parked claim.
    /// @param id The claim to read.
    /// @return The recipient, the token, the amount, and where it came from.
    function pendingClaim(uint64 id) external view returns (PendingClaim memory);

    /// @notice Read a token's parameters.
    /// @param token The ERC20 to read.
    /// @return Its decimals, its ceiling, and whether it is registered and enabled.
    function tokenConfig(address token) external view returns (TokenConfig memory);

    /// @notice How much more of a token may move over a rail in this window.
    /// @param token The ERC20 to read.
    /// @param route The rail to read it for, since each rail has its own ceiling.
    /// @return The remaining headroom, which decays as the window slides rather than resetting.
    function flowAvailable(address token, RouteKind route) external view returns (uint256);

    /// @notice The adapter registered for a rail, or zero.
    /// @param route The rail to read.
    /// @return Its adapter, or the zero address when the rail has not been wired up.
    function adapter(RouteKind route) external view returns (address);

    /// @notice Whether an individual rail is currently paused for departures.
    /// @param route The rail to check.
    /// @return True if the rail is paused.
    function routePaused(RouteKind route) external view returns (bool);
    /// @notice Versioned debit breakdown preserving the legacy quote tuple.
    /// @param route The rail being priced.
    /// @param token The registered source asset.
    /// @param amount Requested source units before fees and flooring.
    /// @param destination Recipient and destination chain.
    /// @param destinationDecimals Decimal precision of the destination asset.
    /// @return The legacy quote with an explicit prospective debit breakdown.
    function quoteV2(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view returns (RouteQuoteV2 memory);
}
