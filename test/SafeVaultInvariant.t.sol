// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockToken} from "../src/MockToken.sol";
import {SafeVault} from "../src/SafeVault.sol";
import {SafeVaultHandler} from "./helpers/SafeVaultHandler.sol";
import {TestBase} from "./helpers/TestBase.sol";

/// @dev Handler assertions and unexpected operation reverts must not be silently discarded.
/// forge-config: default.invariant.fail-on-revert = true
contract SafeVaultInvariantTest is TestBase {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    SafeVaultHandler internal handler;

    function setUp() public {
        MockToken token = new MockToken();
        SafeVault vault = new SafeVault(token, 6);
        handler = new SafeVaultHandler(token, vault);
    }

    // Foundry's invariant targeting ABI, without adding a forge-std dependency.
    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory targets) {
        targets = new FuzzSelector[](1);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = SafeVaultHandler.deposit.selector;
        selectors[1] = SafeVaultHandler.mint.selector;
        selectors[2] = SafeVaultHandler.withdraw.selector;
        selectors[3] = SafeVaultHandler.redeem.selector;
        selectors[4] = SafeVaultHandler.donate.selector;
        selectors[5] = SafeVaultHandler.transferShares.selector;
        selectors[6] = SafeVaultHandler.rejectOverLimit.selector;
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    function invariantAccountingSolvencyAndRounding() public view {
        handler.checkAccounting();
        handler.checkPreviews(0, 0);
        handler.checkPreviews(1, 1);
        handler.checkPreviews(1e27, 1e33);
        handler.checkPreviews(handler.modelAssets(), handler.modelSupply());
    }

    function afterInvariant() public {
        handler.drain(handler.calls(4));
        handler.checkPreviews(1, 1);
    }

    /// @dev Non-vacuity regression: every handler action executes, all four actors own shares,
    /// third parties receive assets, finite/infinite approvals work, and residuals survive reentry.
    function testHandlerExercisesEveryActionAndReentry() public {
        handler.donate(3, 2);
        handler.deposit(0, 1, 11);
        handler.deposit(2, 3, 17);
        handler.mint(1, 2, 2e6 + 1);
        handler.transferShares(1, 0, 1e6);
        for (uint256 i; i < 4; ++i) {
            require(handler.modelShares(i) > 0, "actor has no shares");
        }
        handler.withdraw(1, 2, 0, 1);
        handler.redeem(3, 0, 6, 1);
        handler.rejectOverLimit(0, 0, false);
        handler.rejectOverLimit(2, 0, true);
        for (uint256 i; i < 7; ++i) {
            require(handler.calls(i) > 0, "handler action untested");
        }
        invariantAccountingSolvencyAndRounding();
        handler.drain(2);
        require(handler.modelAssets() > 0, "expected virtual-share residual");
        handler.deposit(0, 0, 100);
        handler.mint(3, 3, 1);
        invariantAccountingSolvencyAndRounding();
        handler.drain(3);
    }
}
