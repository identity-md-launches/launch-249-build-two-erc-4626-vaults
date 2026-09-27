// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockToken} from "../src/MockToken.sol";
import {NaiveVault} from "../src/NaiveVault.sol";
import {SafeVault} from "../src/SafeVault.sol";
import {TestBase} from "./helpers/TestBase.sol";

abstract contract VaultBehaviorTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11);
    MockToken internal token;
    ERC4626 internal vault;

    function _newVault() internal virtual returns (ERC4626);
    function _virtualShares() internal pure virtual returns (uint256);

    function setUp() public {
        token = new MockToken();
        vault = _newVault();
        token.mint(ALICE, 1e30);
        token.mint(BOB, 1e30);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(vault), type(uint256).max);
    }

    function testMetadataAndLimits() public view {
        assertEq(vault.asset(), address(token));
        assertEq(token.decimals(), 18);
        assertEq(vault.decimals(), _virtualShares() == 0 ? 18 : 24);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.maxDeposit(ALICE), type(uint256).max);
        assertEq(vault.maxMint(ALICE), type(uint256).max);
        assertEq(vault.maxWithdraw(ALICE), 0);
        assertEq(vault.maxRedeem(ALICE), 0);
    }

    function testAllFourOperationsRoundTrip() public {
        uint256 k = _virtualShares() == 0 ? 1 : _virtualShares();
        uint256 start = token.balanceOf(ALICE);
        vm.startPrank(ALICE);
        assertEq(vault.deposit(13, ALICE), 13 * k);
        assertEq(vault.mint(2 * k, ALICE), 2);
        assertEq(vault.withdraw(5, ALICE, ALICE), 5 * k);
        assertEq(vault.redeem(10 * k, ALICE, ALICE), 10);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), start);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function testDirectDonationChangesAssetsWithoutMintingShares() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(3, ALICE);
        vm.prank(BOB);
        token.transfer(address(vault), 2);
        assertEq(vault.totalAssets(), 5);
        assertEq(vault.totalSupply(), shares);
        assertEq(vault.balanceOf(BOB), 0);
        _checkPreviews(1, 1);
    }

    function testEmptyVaultDonationAndResidualOnReentry() public {
        vm.prank(BOB);
        token.transfer(address(vault), 9);
        uint256 expected = _virtualShares() == 0 ? 10 : _virtualShares();
        assertEq(vault.previewDeposit(10), expected);
        vm.startPrank(ALICE);
        assertEq(vault.deposit(10, ALICE), expected);
        uint256 assets = vault.redeem(expected, ALICE, ALICE);
        vm.stopPrank();
        assertEq(assets, _virtualShares() == 0 ? 19 : 10);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), _virtualShares() == 0 ? 0 : 9);
        assertEq(vault.previewDeposit(10), expected);
    }

    function testRoundingAndExecutedPreviews() public {
        vm.prank(ALICE);
        vault.deposit(3, ALICE);
        vm.prank(BOB);
        token.transfer(address(vault), 2);
        _checkPreviews(1, 1);
        require(vault.previewWithdraw(1) == vault.previewDeposit(1) + 1, "share rounding not exercised");
        require(vault.previewMint(1) == vault.previewRedeem(1) + 1, "asset rounding not exercised");

        uint256 quote = vault.previewDeposit(1);
        uint256 beforeAssets = vault.totalAssets();
        vm.prank(BOB);
        assertEq(vault.deposit(1, BOB), quote);
        assertEq(vault.balanceOf(BOB), quote);
        assertEq(vault.totalAssets(), beforeAssets + 1);

        _checkPreviews(1, 1);
        quote = vault.previewMint(1);
        beforeAssets = vault.totalAssets();
        vm.prank(BOB);
        assertEq(vault.mint(1, BOB), quote);
        assertEq(vault.totalAssets(), beforeAssets + quote);

        _checkPreviews(1, 1);
        quote = vault.previewWithdraw(1);
        uint256 beforeShares = vault.balanceOf(ALICE);
        beforeAssets = vault.totalAssets();
        vm.prank(ALICE);
        assertEq(vault.withdraw(1, ALICE, ALICE), quote);
        assertEq(vault.balanceOf(ALICE), beforeShares - quote);
        assertEq(vault.totalAssets(), beforeAssets - 1);

        _checkPreviews(1, 1);
        quote = vault.previewRedeem(1);
        beforeAssets = vault.totalAssets();
        vm.prank(ALICE);
        assertEq(vault.redeem(1, ALICE, ALICE), quote);
        assertEq(vault.totalAssets(), beforeAssets - quote);
    }

    function testFuzzPreviewsUseIndependentRoundingModel(uint256 seed, uint256 donation, uint256 amount) public {
        seed = 1 + seed % 1e27;
        donation %= 1e27 + 1;
        amount %= 1e27 + 1;
        vm.startPrank(ALICE);
        vault.deposit(seed, ALICE);
        token.transfer(address(vault), donation);
        vm.stopPrank();
        _checkPreviews(amount, amount);
    }

    function testDepositToOtherReceiverAndTransferShares() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(10, BOB);
        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.balanceOf(BOB), shares);
        vm.prank(BOB);
        vault.transfer(CHARLIE, shares);
        vm.prank(CHARLIE);
        assertEq(vault.redeem(shares, CHARLIE, CHARLIE), 10);
        assertEq(token.balanceOf(CHARLIE), 10);
    }

    function testDelegatedExitsSpendShareAllowance() public {
        vm.startPrank(ALICE);
        uint256 shares = vault.deposit(10, ALICE);
        vault.approve(BOB, shares / 5);
        vm.stopPrank();
        vm.prank(BOB);
        assertEq(vault.withdraw(1, CHARLIE, ALICE), shares / 10);
        assertEq(vault.allowance(ALICE, BOB), shares / 10);
        vm.prank(BOB);
        assertEq(vault.redeem(shares / 10, CHARLIE, ALICE), 1);
        assertEq(vault.allowance(ALICE, BOB), 0);
        assertEq(token.balanceOf(CHARLIE), 2);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", BOB, 0, 1));
        vm.prank(BOB);
        vault.redeem(1, BOB, ALICE);
    }

    function testUnauthorizedWithdrawFails() public {
        vm.prank(ALICE);
        vault.deposit(10, ALICE);
        uint256 shares = vault.previewWithdraw(1);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", BOB, 0, shares));
        vm.prank(BOB);
        vault.withdraw(1, BOB, ALICE);
        assertEq(vault.totalAssets(), 10);
    }

    function testOverWithdrawAndRedeemFail() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(10, ALICE);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, ALICE, 11, 10));
        vm.prank(ALICE);
        vault.withdraw(11, ALICE, ALICE);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, ALICE, shares + 1, shares));
        vm.prank(ALICE);
        vault.redeem(shares + 1, ALICE, ALICE);
        assertEq(vault.totalAssets(), 10);
        assertEq(vault.balanceOf(ALICE), shares);
    }

    function testAssetAllowanceFailureIsAtomic() public {
        token.mint(CHARLIE, 10);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(vault), 0, 10)
        );
        vm.prank(CHARLIE);
        vault.deposit(10, CHARLIE);
        assertEq(token.balanceOf(CHARLIE), 10);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function testAssetBalanceFailureIsAtomic() public {
        vm.prank(CHARLIE);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", CHARLIE, 0, 1));
        vm.prank(CHARLIE);
        vault.deposit(1, CHARLIE);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function testZeroReceiverRevertsTransferAtomically() public {
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        vm.prank(ALICE);
        vault.deposit(10, address(0));
        assertEq(token.balanceOf(ALICE), beforeBalance);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function testZeroOperationsAreNoOps() public {
        vm.startPrank(ALICE);
        assertEq(vault.deposit(0, ALICE), 0);
        assertEq(vault.mint(0, ALICE), 0);
        assertEq(vault.withdraw(0, ALICE, ALICE), 0);
        assertEq(vault.redeem(0, ALICE, ALICE), 0);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function _checkPreviews(uint256 assets, uint256 shares) internal view {
        uint256 virtualShares = _virtualShares();
        uint256 numerator = vault.totalSupply() + virtualShares;
        uint256 denominator = vault.totalAssets() + (virtualShares == 0 ? 0 : 1);
        uint256 shareProduct = assets * numerator;
        uint256 assetProduct = shares * denominator;
        assertEq(vault.convertToShares(assets), shareProduct / denominator);
        assertEq(vault.previewDeposit(assets), shareProduct / denominator);
        assertEq(vault.previewWithdraw(assets), _ceilDiv(shareProduct, denominator));
        assertEq(vault.convertToAssets(shares), assetProduct / numerator);
        assertEq(vault.previewRedeem(shares), assetProduct / numerator);
        assertEq(vault.previewMint(shares), _ceilDiv(assetProduct, numerator));
        assertEq(vault.maxRedeem(ALICE), vault.balanceOf(ALICE));
        assertEq(vault.maxWithdraw(ALICE), vault.balanceOf(ALICE) * denominator / numerator);
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return numerator / denominator + (numerator % denominator == 0 ? 0 : 1);
    }
}

contract NaiveVaultTest is VaultBehaviorTest {
    function _newVault() internal override returns (ERC4626) {
        return new NaiveVault(token);
    }

    function _virtualShares() internal pure override returns (uint256) {
        return 0;
    }
}

contract SafeVaultTest is VaultBehaviorTest {
    function _newVault() internal override returns (ERC4626) {
        return new SafeVault(token, 6);
    }

    function _virtualShares() internal pure override returns (uint256) {
        return 1e6;
    }
}

contract VaultParametersTest is TestBase {
    function testEverySupportedOffsetAndSameUnderlying() public {
        MockToken token = new MockToken();
        NaiveVault naive = new NaiveVault(token);
        assertEq(naive.decimals(), 18);
        assertEq(naive.previewDeposit(1), 1);
        token.mint(address(this), 19);
        for (uint8 offset; offset <= 18; ++offset) {
            SafeVault safe = new SafeVault(token, offset);
            assertEq(safe.asset(), naive.asset());
            assertEq(safe.decimalsOffset(), offset);
            assertEq(safe.decimals(), 18 + offset);
            assertEq(safe.previewDeposit(1), 10 ** uint256(offset));
            token.approve(address(safe), 1);
            assertEq(safe.deposit(1, address(this)), 10 ** uint256(offset));
            token.mint(address(safe), 9);
            assertEq(safe.totalAssets(), 10);
            assertEq(safe.previewRedeem(safe.balanceOf(address(this))), 5);
        }
    }

    function testFuzzRejectUnsupportedOffset(uint8 rawOffset) public {
        uint8 offset = uint8(19 + uint256(rawOffset) % 237);
        MockToken token = new MockToken();
        vm.expectRevert(abi.encodeWithSelector(SafeVault.InvalidDecimalsOffset.selector, offset));
        new SafeVault(token, offset);
    }
}
