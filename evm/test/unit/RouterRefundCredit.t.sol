// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NoRefundCredit, RefundFailed, ZeroAddress} from "../../src/HyperionErrors.sol";
import {HyperionRouter} from "../../src/HyperionRouter.sol";
import {OutboundRequest, RouteKind} from "../../src/HyperionTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/IHyperionRouter.sol";
import {Fixture} from "../Fixture.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

contract RefundCreditCaller {
    enum ReceiveMode {
        Reject,
        Accept,
        ConsumeGas,
        ReenterDispatch,
        ObserveAndReenter
    }

    HyperionRouter private immutable ROUTER;
    OutboundRequest private _replay;
    ReceiveMode public mode;
    bool public withdrawalReentered;
    bool public dispatchReentered;
    uint256 public creditDuringCallback;

    constructor(HyperionRouter router, IERC20 token) {
        ROUTER = router;
        token.approve(address(router), type(uint256).max);
    }

    function setMode(ReceiveMode mode_) external {
        mode = mode_;
    }

    function bridgeCredit(OutboundRequest calldata request) external payable returns (uint64) {
        _replay = request;
        return ROUTER.bridgeOutWithRefundCredit{value: msg.value}(request);
    }

    function bridgeLegacy(OutboundRequest calldata request) external payable returns (uint64) {
        return ROUTER.bridgeOut{value: msg.value}(request);
    }

    function withdrawSelf() external {
        ROUTER.withdrawRefundCredit(payable(address(this)));
    }

    function withdrawTo(address payable recipient) external {
        ROUTER.withdrawRefundCredit(recipient);
    }

    receive() external payable {
        _receiveRefund();
    }

    function _receiveRefund() private {
        if (mode == ReceiveMode.Reject) revert("refund refused");
        if (mode == ReceiveMode.ConsumeGas) {
            while (true) {}
        }
        if (mode == ReceiveMode.ReenterDispatch) ROUTER.bridgeOutWithRefundCredit(_replay);
        if (mode == ReceiveMode.ObserveAndReenter) {
            creditDuringCallback = ROUTER.refundCredits(address(this));
            (withdrawalReentered,) = address(ROUTER)
                .call(abi.encodeCall(HyperionRouter.withdrawRefundCredit, (payable(address(ROUTER)))));
            (dispatchReentered,) =
                address(ROUTER).call(abi.encodeCall(IHyperionRouter.bridgeOutWithRefundCredit, (_replay)));
        }
    }
}

contract RouterRefundCreditTest is Fixture {
    uint256 private constant BUDGET = 10 ether;
    uint256 private constant REFUND = 5 ether;
    RefundCreditCaller private caller;

    function setUp() public override {
        super.setUp();
        caller = new RefundCreditCaller(router, IERC20(address(usdc)));
        usdc.mint(address(caller), 10_000e6);
        vm.deal(address(this), 100 ether);
        cctpRail.setRefund(REFUND);
    }

    function _recordCredit() private {
        assertEq(caller.bridgeCredit{value: BUDGET}(_usdcRequest(1000e6)), 1);
        assertEq(router.refundCredits(address(caller)), REFUND);
        assertEq(address(router).balance, REFUND);
        assertEq(address(caller).balance, 0);
        assertEq(cctpRail.callCount(), 1);
    }

    function test_successful_refund_is_paid_immediately_without_credit() public {
        vm.deal(alice, BUDGET);
        vm.prank(alice);
        router.bridgeOutWithRefundCredit{value: BUDGET}(_usdcRequest(1000e6));
        assertEq(alice.balance, REFUND);
        assertEq(router.refundCredits(alice), 0);
        assertEq(address(router).balance, 0);
        assertEq(usdc.balanceOf(treasury), 1e6);
        assertEq(cctpRail.callCount(), 1);
    }

    function test_failed_refund_records_only_the_original_beneficiary_credit() public {
        _recordCredit();
        assertEq(router.refundCredits(alice), 0);
        assertEq(usdc.balanceOf(address(caller)), 9000e6);
        assertEq(usdc.balanceOf(treasury), 1e6);
        assertEq(cctpRail.lastCall().amount, 999e6);
    }

    function test_permanently_rejecting_beneficiary_can_authorize_another_recipient() public {
        _recordCredit();
        uint256 before = bob.balance;
        caller.withdrawTo(payable(bob));
        assertEq(bob.balance, before + REFUND);
        assertEq(router.refundCredits(address(caller)), 0);
        assertEq(address(router).balance, 0);
        assertEq(router.outboundNonce(), 1);
    }

    function test_other_callers_cannot_withdraw_the_beneficiary_credit() public {
        _recordCredit();
        vm.prank(stranger);
        vm.expectRevert(NoRefundCredit.selector);
        router.withdrawRefundCredit(payable(stranger));
        assertEq(router.refundCredits(address(caller)), REFUND);
        assertEq(address(router).balance, REFUND);
    }

    function test_failed_withdrawal_and_zero_recipient_preserve_the_credit() public {
        _recordCredit();
        vm.expectRevert(RefundFailed.selector);
        caller.withdrawSelf();
        assertEq(router.refundCredits(address(caller)), REFUND);
        vm.expectRevert(ZeroAddress.selector);
        caller.withdrawTo(payable(address(0)));
        assertEq(router.refundCredits(address(caller)), REFUND);
        assertEq(address(router).balance, REFUND);
    }

    function test_legacy_failed_refund_still_reverts_fee_flow_nonce_and_dispatch() public {
        vm.expectRevert(RefundFailed.selector);
        caller.bridgeLegacy{value: BUDGET}(_usdcRequest(1000e6));
        assertEq(usdc.balanceOf(address(caller)), 10_000e6);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), FLOW_LIMIT);
        assertEq(router.refundCredits(address(caller)), 0);
        assertEq(router.outboundNonce(), 0);
        assertEq(cctpRail.callCount(), 0);
        assertEq(address(router).balance, 0);
    }

    function test_previous_credit_is_not_refunded_to_a_later_sender_and_accumulates_exactly() public {
        _recordCredit();
        vm.deal(alice, BUDGET);
        vm.prank(alice);
        router.bridgeOut{value: BUDGET}(_usdcRequest(1000e6));
        assertEq(alice.balance, REFUND);
        assertEq(router.refundCredits(address(caller)), REFUND);
        assertEq(address(router).balance, REFUND);
        caller.bridgeCredit{value: BUDGET}(_usdcRequest(1000e6));
        assertEq(router.refundCredits(address(caller)), 2 * REFUND);
        assertEq(address(router).balance, 2 * REFUND);
        caller.withdrawTo(payable(bob));
        assertEq(address(router).balance, 0);
        assertEq(cctpRail.callCount(), 3);
    }

    function test_gas_consuming_refund_recipient_cannot_prevent_credit_recording() public {
        caller.setMode(RefundCreditCaller.ReceiveMode.ConsumeGas);
        _recordCredit();
        caller.withdrawTo(payable(bob));
        assertEq(router.refundCredits(address(caller)), 0);
    }

    function test_refund_callback_cannot_duplicate_dispatch() public {
        caller.setMode(RefundCreditCaller.ReceiveMode.ReenterDispatch);
        _recordCredit();
        assertEq(router.outboundNonce(), 1);
        assertEq(usdc.balanceOf(address(caller)), 9000e6);
    }

    function test_withdrawal_clears_credit_before_callback_and_blocks_dispatch_reentry() public {
        _recordCredit();
        caller.setMode(RefundCreditCaller.ReceiveMode.ObserveAndReenter);
        caller.withdrawSelf();
        assertEq(caller.creditDuringCallback(), 0);
        assertFalse(caller.withdrawalReentered());
        assertFalse(caller.dispatchReentered());
        assertEq(router.refundCredits(address(caller)), 0);
        assertEq(address(caller).balance, REFUND);
        assertEq(router.outboundNonce(), 1);
        assertEq(cctpRail.callCount(), 1);
        vm.expectRevert(NoRefundCredit.selector);
        caller.withdrawSelf();
    }
}
