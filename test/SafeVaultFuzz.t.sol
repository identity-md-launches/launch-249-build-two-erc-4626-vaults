// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockToken} from "../src/MockToken.sol";
import {SafeVault} from "../src/SafeVault.sol";
import {SafeVaultHandler, SafeVaultOracle} from "./helpers/SafeVaultHandler.sol";
import {TestBase} from "./helpers/TestBase.sol";

contract SafeVaultSequenceFuzzTest is TestBase {
    SafeVaultHandler internal handler;

    function setUp() public {
        MockToken token = new MockToken();
        handler = new SafeVaultHandler(token, new SafeVault(token, 6));
    }

    function testFuzzAllExecutedPreviewsAfterDonations(
        uint256 beforeFirst,
        uint256 seedAssets,
        uint256 donation,
        uint256 assets,
        uint256 shares,
        uint256 actors
    ) public {
        handler.donate(0, SafeVaultOracle.bound(beforeFirst, 1e27));
        handler.deposit(1, 1, 1 + SafeVaultOracle.bound(seedAssets, 1e27 - 1));
        handler.donate(2, SafeVaultOracle.bound(donation, 1e27));
        handler.checkAccounting();
        assets = SafeVaultOracle.bound(assets, 1e27);
        shares = SafeVaultOracle.bound(shares, 1e33);
        handler.checkPreviews(assets, shares);

        handler.deposit(actors, 3, assets);
        handler.checkAccounting();
        handler.checkPreviews(assets, shares);
        handler.mint(actors >> 8, 3, shares);
        handler.checkAccounting();
        handler.checkPreviews(assets, shares);
        handler.withdraw(3, actors >> 16, actors >> 24, assets);
        handler.checkAccounting();
        handler.checkPreviews(assets, shares);
        handler.redeem(3, actors >> 32, actors >> 40, shares);
        handler.checkAccounting();
        handler.drain(actors);
    }

    function testFuzzZeroCallsAreNoOpsAfterDonation(uint256 donation, uint256 seedAssets) public {
        handler.deposit(0, 0, SafeVaultOracle.bound(seedAssets, 1e27));
        handler.donate(1, SafeVaultOracle.bound(donation, 1e27));
        uint256 assetsBefore = handler.modelAssets();
        uint256 supplyBefore = handler.modelSupply();
        handler.deposit(0, 1, 0);
        handler.mint(1, 2, 0);
        handler.withdraw(2, 3, 0, 0);
        handler.redeem(3, 0, 1, 0);
        handler.checkAccounting();
        assertEq(handler.modelAssets(), assetsBefore);
        assertEq(handler.modelSupply(), supplyBefore);
    }
}

contract SafeVaultAdversarialFuzzTest is TestBase {
    uint256 internal constant LIMIT = 1e27;
    uint256 internal constant K = 1e6;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant EMPTY = address(0xCA11);
    MockToken internal token;
    SafeVault internal vault;

    function setUp() public {
        token = new MockToken();
        vault = new SafeVault(token, 6);
        token.mint(ALICE, 1e30);
        token.mint(BOB, 1e30);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(vault), type(uint256).max);
    }

    function testFuzzDonationBeforeFirstDepositNeverProfits(uint256 d, uint256 v) public {
        _attack(SafeVaultOracle.bound(d, LIMIT), SafeVaultOracle.bound(v, LIMIT), true);
    }

    function testFuzzSeedThenDonationNeverProfits(uint256 d, uint256 v) public {
        _attack(SafeVaultOracle.bound(d, LIMIT), SafeVaultOracle.bound(v, LIMIT), false);
    }

    function testDonationBeforeFirstDepositBoundaryGrid() public {
        // D = K - 1 / K straddles the attacker's first zero-share deposit.
        uint256[9] memory values = [uint256(0), 1, K - 1, K, K + 1, 1e18, 1e24, LIMIT - 1, LIMIT];
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j; j < values.length; ++j) {
                vault = new SafeVault(token, 6);
                vm.prank(ALICE);
                token.approve(address(vault), type(uint256).max);
                vm.prank(BOB);
                token.approve(address(vault), type(uint256).max);
                _attack(values[i], values[j], true);
            }
        }
    }

    function testFuzzDepositAndMintRoundTripsCannotCreateAssets(
        uint256 seedAssets,
        uint256 donation,
        uint256 rawAmount,
        bool mintShares
    ) public {
        _seed(seedAssets, donation);
        // Bound a mint by an independently calculated affordable share count.
        uint256 budget = 1 + SafeVaultOracle.bound(rawAmount, LIMIT - 1);
        uint256 amount =
            mintShares ? SafeVaultOracle.down(budget, vault.totalSupply() + K, vault.totalAssets() + 1) : budget;
        uint256 beforeTokens = token.balanceOf(BOB);
        vm.startPrank(BOB);
        if (mintShares) vault.mint(amount, BOB);
        else vault.deposit(amount, BOB);
        uint256 heldShares = vault.balanceOf(BOB);
        uint256 quote = vault.previewRedeem(heldShares);
        assertEq(vault.redeem(heldShares, BOB, BOB), quote);
        vm.stopPrank();
        assertLe(token.balanceOf(BOB), beforeTokens);
        assertEq(vault.balanceOf(BOB), 0);
    }

    function testFuzzEntryAllowanceFailureIsAtomic(uint256 donation, uint256 rawAmount, bool mintShares) public {
        _seed(16, donation);
        uint256 amount = 1 + SafeVaultOracle.bound(rawAmount, LIMIT - 1);
        uint256 cost = mintShares ? _mintCost(amount) : amount;
        token.mint(BOB, cost); // Sufficient balance isolates the allowance failure.
        vm.prank(BOB);
        token.approve(address(vault), cost - 1);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(vault), cost - 1, cost
            )
        );
        vm.prank(BOB);
        if (mintShares) vault.mint(amount, BOB);
        else vault.deposit(amount, BOB);
        require(_state() == beforeState, "failed entry changed balances or allowances");
    }

    function testFuzzEntryBalanceFailureRestoresFiniteAllowance(uint256 donation, uint256 rawAmount, bool mintShares)
        public
    {
        _seed(16, donation);
        uint256 amount = 1 + SafeVaultOracle.bound(rawAmount, LIMIT - 1);
        uint256 cost = mintShares ? _mintCost(amount) : amount;
        vm.prank(EMPTY);
        token.approve(address(vault), cost);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", EMPTY, 0, cost));
        vm.prank(EMPTY);
        if (mintShares) vault.mint(amount, EMPTY);
        else vault.deposit(amount, EMPTY);
        require(_state() == beforeState, "failed transfer consumed allowance");
    }

    function testFuzzExitAllowanceFailureIsAtomic(
        uint256 seedAssets,
        uint256 donation,
        uint256 rawAmount,
        bool redeemShares
    ) public {
        _seed(seedAssets, donation);
        uint256 maximum = redeemShares ? vault.balanceOf(ALICE) : _redeemValue(vault.balanceOf(ALICE));
        uint256 amount = 1 + SafeVaultOracle.bound(rawAmount, maximum - 1);
        uint256 needed = redeemShares ? amount : _withdrawCost(amount);
        vm.prank(ALICE);
        vault.approve(BOB, needed - 1);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", BOB, needed - 1, needed)
        );
        vm.prank(BOB);
        if (redeemShares) vault.redeem(amount, BOB, ALICE);
        else vault.withdraw(amount, BOB, ALICE);
        require(_state() == beforeState, "unauthorized exit changed state");
    }

    function testFuzzZeroReceiverRollsBackAllFourOperations(uint256 donation, uint8 operation) public {
        _seed(16, donation);
        operation %= 4;
        // Exact finite allowances expose rollback bugs after transferFrom, allowance spending,
        // or burning has happened but the eventual zero-address mint/transfer fails.
        uint256 assetAllowance = operation == 1 ? _mintCost(1) : 1;
        uint256 shareAllowance = operation == 2 ? _withdrawCost(1) : 1;
        vm.prank(ALICE);
        token.approve(address(vault), assetAllowance);
        vm.prank(ALICE);
        vault.approve(BOB, shareAllowance);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        vm.prank(operation < 2 ? ALICE : BOB);
        if (operation == 0) vault.deposit(1, address(0));
        else if (operation == 1) vault.mint(1, address(0));
        else if (operation == 2) vault.withdraw(1, address(0), ALICE);
        else vault.redeem(1, address(0), ALICE);
        require(_state() == beforeState, "zero receiver failure was not atomic");
    }

    function testFuzzFiniteExitAllowanceCannotBeReused(uint256 donation, bool redeemShares) public {
        _seed(16, donation);
        uint256 amount = redeemShares ? K : 1;
        uint256 needed = redeemShares ? amount : _withdrawCost(amount);
        vm.prank(ALICE);
        vault.approve(BOB, needed);
        uint256 quote = redeemShares ? _redeemValue(amount) : needed;
        vm.prank(BOB);
        if (redeemShares) assertEq(vault.redeem(amount, BOB, ALICE), quote);
        else assertEq(vault.withdraw(amount, BOB, ALICE), quote);
        assertEq(vault.allowance(ALICE, BOB), 0);
        // Recompute the quote because the first exit may have changed the exchange rate.
        needed = redeemShares ? amount : _withdrawCost(amount);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", BOB, 0, needed));
        vm.prank(BOB);
        if (redeemShares) vault.redeem(amount, BOB, ALICE);
        else vault.withdraw(amount, BOB, ALICE);
        require(_state() == beforeState, "spent allowance reused");
    }

    function _attack(uint256 d, uint256 v, bool donateFirst) private {
        uint256 start = token.balanceOf(ALICE);
        vm.startPrank(ALICE);
        if (donateFirst) token.transfer(address(vault), d);
        uint256 initialShares = donateFirst ? K / (d + 1) : K;
        assertEq(vault.previewDeposit(1), initialShares);
        assertEq(vault.deposit(1, ALICE), initialShares);
        if (!donateFirst) token.transfer(address(vault), d);
        vm.stopPrank();

        uint256 victimShares = v * (initialShares + K) / (d + 2);
        assertEq(vault.previewDeposit(v), victimShares);
        vm.prank(BOB);
        assertEq(vault.deposit(v, BOB), victimShares);
        uint256 expectedReturn = initialShares * (d + v + 2) / (initialShares + victimShares + K);
        assertEq(vault.previewRedeem(initialShares), expectedReturn);
        vm.prank(ALICE);
        assertEq(vault.redeem(initialShares, ALICE, ALICE), expectedReturn);
        assertLe(expectedReturn, d + 1);
        assertLe(token.balanceOf(ALICE), start);
        assertEq(vault.balanceOf(ALICE), 0);

        uint256 victimReturn = victimShares * (d + v + 2 - expectedReturn) / (victimShares + K);
        assertEq(vault.previewRedeem(victimShares), victimReturn);
        assertLe(victimReturn, vault.totalAssets());
        vm.prank(BOB);
        assertEq(vault.redeem(victimShares, BOB, BOB), victimReturn);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), token.balanceOf(address(vault)));
        assertEq(expectedReturn + victimReturn + vault.totalAssets(), d + v + 1);
    }

    function _seed(uint256 rawSeed, uint256 rawDonation) private {
        uint256 seedAssets = 1 + SafeVaultOracle.bound(rawSeed, LIMIT - 1);
        vm.startPrank(ALICE);
        vault.deposit(seedAssets, ALICE);
        token.transfer(address(vault), SafeVaultOracle.bound(rawDonation, LIMIT));
        vm.stopPrank();
    }

    function _mintCost(uint256 shares) private view returns (uint256) {
        return SafeVaultOracle.up(shares, vault.totalAssets() + 1, vault.totalSupply() + K);
    }

    function _withdrawCost(uint256 assets) private view returns (uint256) {
        return SafeVaultOracle.up(assets, vault.totalSupply() + K, vault.totalAssets() + 1);
    }

    function _redeemValue(uint256 shares) private view returns (uint256) {
        return SafeVaultOracle.down(shares, vault.totalAssets() + 1, vault.totalSupply() + K);
    }

    function _state() private view returns (bytes32) {
        bytes32 balances = keccak256(
            abi.encode(
                vault.totalAssets(),
                vault.totalSupply(),
                token.totalSupply(),
                token.balanceOf(address(vault)),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(EMPTY),
                vault.balanceOf(ALICE),
                vault.balanceOf(BOB),
                vault.balanceOf(EMPTY)
            )
        );
        return keccak256(
            abi.encode(
                balances,
                token.allowance(ALICE, address(vault)),
                token.allowance(BOB, address(vault)),
                token.allowance(EMPTY, address(vault)),
                vault.allowance(ALICE, BOB)
            )
        );
    }
}
