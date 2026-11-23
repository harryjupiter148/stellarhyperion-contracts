// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

import {HyperionRouter} from "../src/HyperionRouter.sol";
import {
    ActionKind,
    AdminAction,
    Origin,
    OutboundRequest,
    PendingClaim,
    RouteKind
} from "../src/HyperionTypes.sol";
import {Fixture} from "./Fixture.sol";

/// @title Independent EVM state specification and driver
/// @notice No AmountMath, SlidingWindow, router storage or router quote calls supply expected state.
contract RouterModelDriver is Fixture {
    using SafeCast for uint256;
    uint256 internal constant FUNDS = 10_000_000_000_000;
    uint256 internal constant LIMIT = 1_000_000_000;

    struct ModelClaim {
        uint256 amount;
        uint256 recipient;
        bool settled;
    }

    struct ModelAction {
        uint256 bps;
        uint256 eta;
        bool pending;
    }

    struct ModelWindow {
        uint256 epoch;
        uint256 current;
        uint256 previous;
    }

    struct Model {
        uint256[6] balances;
        bool[2] blocked;
        bool[16] seen;
        ModelClaim[128] claims;
        ModelAction[128] actions;
        ModelWindow[4] windows;
        uint256 timestamp;
        uint256 fee;
        uint256 nonce;
        uint256 claimCount;
        uint256 actionCount;
        bool paused;
    }
    Model internal model;
    uint64 internal queueBase;

    /// @notice Initialize the real router and a separately funded reference universe.
    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        router.lowerTokenFlowLimit(address(usdc), LIMIT);
        usdc.mint(railReceiver, FUNDS);
        vm.prank(railReceiver);
        usdc.approve(address(router), type(uint256).max);
        vm.warp(1_701_000_000);
        queueBase = router.actionCount();
        model.balances = [FUNDS, 0, FUNDS, 0, 0, 0];
        model.timestamp = block.timestamp;
        model.fee = 10;
    }

    function _rolled(uint256 rail) internal view returns (ModelWindow memory w) {
        w = model.windows[rail];
        uint256 epoch = model.timestamp / 3600;
        if (epoch != w.epoch) {
            w.previous = epoch == w.epoch + 1 ? w.current : 0;
            w.current = 0;
            w.epoch = epoch;
        }
    }

    function _available(uint256 rail) internal view returns (uint256) {
        ModelWindow memory w = _rolled(rail);
        uint256 used = w.current + w.previous * (3600 - model.timestamp % 3600) / 3600;
        return used >= LIMIT ? 0 : LIMIT - used;
    }

    function _recipient(uint256 index) internal view returns (address) {
        return index == 0 ? bob : stranger;
    }

    function _actor(uint256 index) internal view returns (address) {
        return index == 0 ? admin : index == 1 ? guardian : alice;
    }

    function _predictDispatch(uint256 small, uint256 arg) internal returns (bool, uint256) {
        uint256 amount = arg % 1_500_000_000;
        uint256 fee = amount * model.fee / 10_000;
        uint256 net = amount - fee;
        if (model.paused || net == 0 || amount > model.balances[0] || net > _available(small % 4)) {
            return (false, 0);
        }
        ModelWindow memory w = _rolled(small % 4);
        w.current += net;
        model.windows[small % 4] = w;
        model.balances[0] -= amount;
        model.balances[1] += fee;
        model.balances[2] += net;
        return (true, ++model.nonce);
    }

    function _predictInbound(uint256 small, uint256 arg, uint256 nonce) internal returns (bool, uint256) {
        uint256 amount = arg % 1_500_000_000;
        uint256 recipient = small % 2;
        if (amount == 0 || amount > model.balances[2] || model.seen[nonce]) return (false, 0);
        model.seen[nonce] = true;
        model.balances[2] -= amount;
        if (model.blocked[recipient]) {
            model.claims[model.claimCount++] =
                ModelClaim({amount: amount, recipient: recipient, settled: false});
            model.balances[3] += amount;
            return (true, model.claimCount);
        }
        model.balances[4 + recipient] += amount;
        return (true, 0);
    }

    function _predictAction(uint256 kind, uint256 actor, uint256 arg) internal returns (bool, uint256) {
        if (kind == 6) {
            if (actor != 0 || arg % 121 > 100) return (false, 0);
            model.actions[model.actionCount++] =
                ModelAction({bps: arg % 121, eta: model.timestamp + 172_800, pending: true});
            return (true, model.actionCount);
        }
        uint256 id = arg % 20;
        if (actor > 1 || (kind == 7 && actor != 0) || id >= model.actionCount) return (false, 0);
        ModelAction storage action = model.actions[id];
        if (!action.pending) return (false, 0);
        if (kind == 7) {
            if (model.timestamp < action.eta || model.timestamp > action.eta + 604_800) return (false, 0);
            model.fee = action.bps;
        }
        action.pending = false;
        return (true, 0);
    }

    function _predict(uint64 word) internal returns (bool, uint256) {
        uint256 kind = (uint256(word) & 255) % 10;
        uint256 small = uint256(word) >> 8;
        uint256 arg = uint256(word) >> 16;
        if (kind == 0) return _predictDispatch(small, arg);
        if (kind == 1) return _predictInbound(small, arg, (uint256(word) >> 10) % 16);
        if (kind == 2) {
            model.blocked[small % 2] = arg % 2 != 0;
            return (true, 0);
        }
        if (kind == 3) {
            uint256 id = small % 20;
            if (id >= model.claimCount) return (false, 0);
            ModelClaim storage claim = model.claims[id];
            if (claim.settled || model.blocked[claim.recipient]) return (false, 0);
            claim.settled = true;
            model.balances[3] -= claim.amount;
            model.balances[4 + claim.recipient] += claim.amount;
            return (true, 0);
        }
        if (kind == 4 || kind == 5) {
            bool pause = kind == 4;
            uint256 actor = small % 3;
            if (actor > 1 || (!pause && actor != 0) || model.paused == pause) return (false, 0);
            model.paused = pause;
            return (true, 0);
        }
        if (kind < 9) return _predictAction(kind, small % 3, arg);
        model.timestamp += arg % 800_000;
        return (true, 0);
    }

    function _real(uint64 word) internal returns (bool ok, uint256 result) {
        uint256 kind = (uint256(word) & 255) % 10;
        uint256 small = uint256(word) >> 8;
        uint256 arg = uint256(word) >> 16;
        if (kind == 2) {
            usdc.setBlocked(_recipient(small % 2), arg % 2 != 0);
            return (true, 0);
        }
        if (kind == 9) {
            vm.warp(block.timestamp + arg % 800_000);
            return (true, 0);
        }
        bytes memory payload;
        address caller = _actor(small % 3);
        if (kind == 0) {
            return _realDispatch(small, arg);
        }
        if (kind == 1) {
            uint64 nonce = ((uint256(word) >> 10) % 16).toUint64();
            Origin memory origin = Origin({
                chain: "stellar",
                nonce: nonce,
                messageId: bytes32(uint256(nonce)),
                sender: bytes32(uint256(7))
            });
            payload = abi.encodeCall(
                HyperionRouter.bridgeIn,
                (RouteKind.Cctp, address(usdc), arg % 1_500_000_000, _recipient(small % 2), origin)
            );
            caller = railReceiver;
        } else if (kind == 3) {
            payload = abi.encodeCall(HyperionRouter.settleClaim, ((small % 20 + 1).toUint64()));
            caller = alice;
        } else if (kind == 4) {
            payload = abi.encodeCall(HyperionRouter.pause, ());
        } else if (kind == 5) {
            payload = abi.encodeCall(HyperionRouter.unpause, ());
        } else if (kind == 6) {
            AdminAction memory action = _empty(ActionKind.SetFeeBps);
            action.amount = arg % 121;
            payload = abi.encodeCall(HyperionRouter.queueAction, (action));
        } else if (kind == 7) {
            payload = abi.encodeCall(HyperionRouter.executeAction, (queueBase + (arg % 20 + 1).toUint64()));
        } else {
            payload = abi.encodeCall(
                HyperionRouter.cancelActionWithReason,
                (queueBase + (arg % 20 + 1).toUint64(), CancelReason.Unspecified, "")
            );
        }
        vm.prank(caller);
        bytes memory data;
        (ok, data) = address(router).call(payload);
        if (ok && (kind == 1 || kind == 6)) {
            result = abi.decode(data, (uint64));
            if (kind == 6) result -= queueBase;
        }
    }

    function _realDispatch(uint256 small, uint256 arg) internal returns (bool ok, uint256 result) {
        // Use the actual production entrypoint rather than a quote or a test double router.
        vm.prank(alice);
        try router.bridgeOut(_modelRequest(small, arg)) returns (uint64 nonce) {
            return (true, nonce);
        } catch {
            return (false, 0);
        }
    }

    function _modelRequest(uint256 small, uint256 arg) internal view returns (OutboundRequest memory) {
        OutboundRequest memory request = _usdcRequest(arg % 1_500_000_000);
        request.route = RouteKind(small % 4);
        return request;
    }

    /// @notice Compare every transition; Foundry keeps and shrinks failing input words/call sequences.
    function applyWord(uint64 word) public returns (bool actual, uint256 observed) {
        (bool expected, uint256 result) = _predict(word);
        (actual, observed) = _real(word);
        assertEq(actual, expected, string.concat("outcome word=", vm.toString(word)));
        if (actual) assertEq(observed, result, "operation result");
        _assertState();
    }

    function _assertState() internal view {
        uint256 rail = usdc.balanceOf(railReceiver) + usdc.balanceOf(address(cctpRail))
            + usdc.balanceOf(address(itsRail)) + usdc.balanceOf(address(gmpRail))
            + usdc.balanceOf(address(allbridgeRail));
        uint256[6] memory balances = [
            usdc.balanceOf(alice),
            usdc.balanceOf(treasury),
            rail,
            usdc.balanceOf(address(router)),
            usdc.balanceOf(bob),
            usdc.balanceOf(stranger)
        ];
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            assertEq(balances[i], model.balances[i], "balance");
            sum += balances[i];
        }
        assertEq(sum, 2 * FUNDS, "token conservation");
        assertEq(router.paused(), model.paused, "pause");
        assertEq(router.feeBps(), model.fee, "fee");
        assertEq(router.outboundNonce(), model.nonce, "nonce");
        assertEq(router.claimCount(), model.claimCount, "claim count");
        assertEq(router.actionCount() - queueBase, model.actionCount, "queue count");
        uint256[2] memory liabilities = _liabilities();
        assertEq(liabilities[0] + liabilities[1], balances[3], "claim collateral");
        for (uint256 i; i < 4; ++i) {
            assertEq(router.flowAvailable(address(usdc), RouteKind(i)), _available(i), "flow");
        }
    }

    function _liabilities() internal view returns (uint256[2] memory sums) {
        for (uint256 i; i < model.claimCount; ++i) {
            ModelClaim storage expected = model.claims[i];
            PendingClaim memory actual = router.pendingClaim((i + 1).toUint64());
            assertEq(actual.recipient, _recipient(expected.recipient), "fixed recipient");
            assertEq(actual.amount, expected.amount, "claim amount");
            assertEq(actual.settled, expected.settled, "settled");
            if (!actual.settled) sums[expected.recipient] += actual.amount;
        }
    }
}

/// @title Generated stateful invariant campaign
/// @notice Foundry shrinks failing call sequences and retains the complete reproduction.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract StatefulRouterInvariantTest is RouterModelDriver {
    /// @notice Only portable operation words are eligible generated actions.
    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.applyWord.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /// @notice Every transition checks the reference; this also checks each campaign's final state.
    function invariant_conservedBalancesAndFixedRecipientLiabilities() public view {
        _assertState();
    }
}

/// @title Stateful real-router comparison
/// @notice Fresh fuzz sequences and invariant call-sequence shrinking complement the common Rust corpus.
contract StatefulRouterModelTest is RouterModelDriver {
    /// @notice A deliberately wrong expected balance produces a fatal comparison assertion.
    function test_comparisonRejectsInjectedBalanceDivergence() public {
        ++model.balances[0];
        vm.expectRevert();
        this.applyWord(2);
    }

    /// @notice Arbitrary inputs shrink in both values and independent operation words.
    function testFuzz_operationSequence(uint64[8] memory words) public {
        for (uint256 i; i < words.length; ++i) {
            applyWord(words[i]);
        }
    }

    /// @notice The very same words and independent expected observations are run on Soroban.
    function test_commonRustGeneratedCorpus() public {
        string memory path = "../testdata/router-model-evm.csv";
        vm.readLine(path); // header
        for (uint256 i; i < 64; ++i) {
            uint256[20] memory row = _parse(vm.readLine(path));
            (bool success, uint256 result) = applyWord(SafeCast.toUint64(row[0]));
            assertEq(success, row[1] != 0, "Rust model outcome");
            assertEq(result, row[2], "Rust model result");
            for (uint256 j; j < 6; ++j) {
                assertEq(model.balances[j], row[3 + j], "Rust model balance");
            }
            assertEq(model.paused, row[9] != 0);
            assertEq(model.fee, row[10]);
            assertEq(model.nonce, row[11]);
            assertEq(model.claimCount, row[12]);
            assertEq(model.actionCount, row[13]);
            for (uint256 j; j < 4; ++j) {
                assertEq(_available(j), row[14 + j]);
            }
            uint256[2] memory liabilities = _liabilities();
            assertEq(liabilities[0], row[18]);
            assertEq(liabilities[1], row[19]);
        }
        assertEq(bytes(vm.readLine(path)).length, 0, "complete corpus");
        vm.closeFile(path);
    }

    function _parse(string memory line) internal pure returns (uint256[20] memory values) {
        bytes memory data = bytes(line);
        uint256 index;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == ",") ++index;
            else values[index] = values[index] * 10 + uint8(data[i]) - 48;
        }
        require(index == 19, "model corpus row");
    }
}
