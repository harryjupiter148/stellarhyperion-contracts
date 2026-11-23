// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployConfig} from "../../script/DeployConfig.sol";
import {Test} from "forge-std/Test.sol";

contract CompatibilityHarness is DeployConfig {
    function target() external view {
        requireCompatibleExecutionTarget();
    }

    function profile(string calldata artifact) external pure returns (CompatibilityProfile memory) {
        return _validateArtifactProfileJson(artifact);
    }
}

contract DeploymentCompatibilityTest is Test {
    CompatibilityHarness private harness;

    function setUp() public {
        harness = new CompatibilityHarness();
        vm.setEnv("HYPERION_EVM_VERSION", "cancun");
        vm.setEnv("HYPERION_SOLC_VERSION", "0.8.28");
    }

    function test_actualPinnedArtifactsSupportLocalChains() public {
        vm.chainId(31_337);
        harness.target();
        vm.chainId(1337);
        harness.target();
    }

    function test_unsupportedChainAndForkFailBeforeProposals() public {
        vm.chainId(42);
        vm.expectRevert("unsupported deployment chain");
        harness.target();
        vm.chainId(31_337);
        vm.setEnv("HYPERION_EVM_VERSION", "shanghai");
        vm.expectRevert("unsupported EVM revision; use cancun");
        harness.target();
        vm.setEnv("HYPERION_EVM_VERSION", "cancun");
    }

    function test_actualMetadataRejectsFalseLabelsAndUnsupportedBuildSettings() public {
        string memory good = _artifact("0.8.28+commit.7893614a", "cancun", "true", "50", "true");
        DeployConfig.CompatibilityProfile memory profile = harness.profile(good);
        assertEq(profile.compilerVersion, "0.8.28+commit.7893614a");
        assertEq(profile.evmVersion, "cancun");
        vm.expectRevert("artifact compiler revision mismatch");
        harness.profile(_artifact("0.8.27+commit.40a35a09", "cancun", "true", "50", "true"));
        vm.expectRevert("artifact EVM revision mismatch");
        harness.profile(_artifact("0.8.28+commit.7893614a", "shanghai", "true", "50", "true"));
        vm.expectRevert("artifact optimizer profile mismatch");
        harness.profile(_artifact("0.8.28+commit.7893614a", "cancun", "false", "50", "true"));
        vm.expectRevert("artifact optimizer profile mismatch");
        harness.profile(_artifact("0.8.28+commit.7893614a", "cancun", "true", "1000", "true"));
        vm.expectRevert("artifact optimizer profile mismatch");
        harness.profile(_artifact("0.8.28+commit.7893614a", "cancun", "true", "50", "false"));
    }

    function _artifact(
        string memory compiler,
        string memory revision,
        string memory enabled,
        string memory runs,
        string memory viaIR
    ) private pure returns (string memory) {
        return string.concat(
            "{\"metadata\":{\"compiler\":{\"version\":\"",
            compiler,
            "\"},\"settings\":{\"evmVersion\":\"",
            revision,
            "\",\"optimizer\":{\"enabled\":",
            enabled,
            ",\"runs\":",
            runs,
            "},\"viaIR\":",
            viaIR,
            "}}}"
        );
    }
}
