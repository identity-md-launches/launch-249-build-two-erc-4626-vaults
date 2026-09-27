// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockToken} from "../../src/MockToken.sol";
import {SafeVault} from "../../src/SafeVault.sol";
import {TestBase} from "./TestBase.sol";

/// @dev Independent integer oracle; deliberately does not use the vault's Math.mulDiv.
/// With four actors funded with 1e30 each, assets <= 4e30 and shares <= 4e36.
/// All products used by this harness fit in uint256, including after arbitrarily many steps.
library SafeVaultOracle {
    uint256 internal constant K = 1e6;

    function down(uint256 amount, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return amount * numerator / denominator;
    }

    function up(uint256 amount, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        uint256 product = amount * numerator;
        return product / denominator + (product % denominator == 0 ? 0 : 1);
    }

    function bound(uint256 value, uint256 maximum) internal pure returns (uint256) {
        return value <= maximum ? value : value % (maximum + 1);
    }
}

contract SafeVaultHandler is TestBase {
    uint256 public constant ACTORS = 4;
    uint256 public constant FUNDING = 1e30;
    uint256 internal constant LIMIT = 1e27;
    MockToken public immutable token;
    SafeVault public immutable vault;

    // Model balances change only according to the inputs and independent rounding oracle.
    uint256 public modelAssets;
    uint256 public modelSupply;
    uint256[4] public modelTokens;
    uint256[4] public modelShares;
    uint256 public deposited;
    uint256 public donated;
    uint256 public paidOut;
    uint256[7] public calls;

    constructor(MockToken token_, SafeVault vault_) {
        token = token_;
        vault = vault_;
        for (uint256 i; i < ACTORS; ++i) {
            token.mint(actor(i), FUNDING);
            modelTokens[i] = FUNDING;
            vm.prank(actor(i));
            token.approve(address(vault), type(uint256).max);
        }
    }

    function actor(uint256 seed) public pure returns (address) {
        return address(uint160(0x1000 + seed % ACTORS));
    }

    function deposit(uint256 payerSeed, uint256 receiverSeed, uint256 rawAssets) external {
        uint256 payer = payerSeed % ACTORS;
        uint256 receiver = receiverSeed % ACTORS;
        uint256 assets = _amount(rawAssets, _min(modelTokens[payer], LIMIT));
        uint256 shares = _sharesDown(assets);
        assertEq(vault.previewDeposit(assets), shares);
        vm.prank(actor(payer));
        assertEq(vault.deposit(assets, actor(receiver)), shares);
        _enter(payer, receiver, assets, shares);
        ++calls[0];
    }

    function mint(uint256 payerSeed, uint256 receiverSeed, uint256 rawShares) external {
        uint256 payer = payerSeed % ACTORS;
        uint256 receiver = receiverSeed % ACTORS;
        // Bound by an asset budget using the model, not previewMint/convertToShares.
        uint256 affordable = _sharesDown(_min(modelTokens[payer], LIMIT));
        uint256 shares = _amount(rawShares, _min(affordable, LIMIT * SafeVaultOracle.K));
        uint256 assets = _assetsUp(shares);
        assertEq(vault.previewMint(shares), assets);
        vm.prank(actor(payer));
        assertEq(vault.mint(shares, actor(receiver)), assets);
        _enter(payer, receiver, assets, shares);
        ++calls[1];
    }

    function withdraw(uint256 ownerSeed, uint256 receiverSeed, uint256 callerSeed, uint256 rawAssets) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 receiver = receiverSeed % ACTORS;
        uint256 assets = _amount(rawAssets, _assetsDown(modelShares[owner]));
        uint256 shares = _sharesUp(assets);
        assertEq(vault.previewWithdraw(assets), shares);
        _approveExit(owner, callerSeed, shares);
        vm.prank(actor(callerSeed));
        assertEq(vault.withdraw(assets, actor(receiver), actor(owner)), shares);
        _checkAllowance(owner, callerSeed);
        _exit(owner, receiver, assets, shares);
        ++calls[2];
    }

    function redeem(uint256 ownerSeed, uint256 receiverSeed, uint256 callerSeed, uint256 rawShares) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 receiver = receiverSeed % ACTORS;
        uint256 shares = _amount(rawShares, modelShares[owner]);
        uint256 assets = _assetsDown(shares);
        assertEq(vault.previewRedeem(shares), assets);
        _approveExit(owner, callerSeed, shares);
        vm.prank(actor(callerSeed));
        assertEq(vault.redeem(shares, actor(receiver), actor(owner)), assets);
        _checkAllowance(owner, callerSeed);
        _exit(owner, receiver, assets, shares);
        ++calls[3];
    }

    function donate(uint256 donorSeed, uint256 rawAssets) external {
        uint256 donor = donorSeed % ACTORS;
        uint256 assets = _amount(rawAssets, _min(modelTokens[donor], LIMIT));
        vm.prank(actor(donor));
        require(token.transfer(address(vault), assets), "donation transfer");
        modelTokens[donor] -= assets;
        modelAssets += assets;
        donated += assets;
        ++calls[4];
    }

    function transferShares(uint256 senderSeed, uint256 receiverSeed, uint256 rawShares) external {
        uint256 sender = senderSeed % ACTORS;
        uint256 receiver = receiverSeed % ACTORS;
        uint256 shares = _amount(rawShares, modelShares[sender]);
        vm.prank(actor(sender));
        require(vault.transfer(actor(receiver), shares), "share transfer");
        modelShares[sender] -= shares;
        modelShares[receiver] += shares;
        ++calls[5];
    }

    /// @dev Expected reverts are caught here. Unexpected reverts/assertion failures must fail
    /// the campaign: the invariant test explicitly enables fail-on-revert.
    function rejectOverLimit(uint256 ownerSeed, uint256 extraSeed, bool redeemShares) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 extra = 1 + SafeVaultOracle.bound(extraSeed, LIMIT - 1);
        if (redeemShares) {
            uint256 maximum = modelShares[owner];
            vm.expectRevert(
                abi.encodeWithSelector(
                    ERC4626.ERC4626ExceededMaxRedeem.selector, actor(owner), maximum + extra, maximum
                )
            );
            vm.prank(actor(owner));
            vault.redeem(maximum + extra, actor(owner), actor(owner));
        } else {
            uint256 maximum = _assetsDown(modelShares[owner]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ERC4626.ERC4626ExceededMaxWithdraw.selector, actor(owner), maximum + extra, maximum
                )
            );
            vm.prank(actor(owner));
            vault.withdraw(maximum + extra, actor(owner), actor(owner));
        }
        ++calls[6];
        checkAccounting();
    }

    function checkAccounting() public view {
        assertEq(vault.totalAssets(), modelAssets);
        assertEq(token.balanceOf(address(vault)), modelAssets);
        assertEq(vault.totalSupply(), modelSupply);
        assertEq(deposited + donated, modelAssets + paidOut);
        uint256 shares;
        uint256 tokens = modelAssets;
        uint256 claims;
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(vault.balanceOf(actor(i)), modelShares[i]);
            assertEq(token.balanceOf(actor(i)), modelTokens[i]);
            assertEq(vault.maxRedeem(actor(i)), modelShares[i]);
            assertEq(vault.maxWithdraw(actor(i)), _assetsDown(modelShares[i]));
            assertEq(vault.previewRedeem(modelShares[i]), _assetsDown(modelShares[i]));
            shares += modelShares[i];
            tokens += modelTokens[i];
            claims += vault.previewRedeem(modelShares[i]);
        }
        assertEq(shares, modelSupply);
        assertEq(tokens, ACTORS * FUNDING);
        assertEq(token.totalSupply(), ACTORS * FUNDING);
        assertLe(claims, modelAssets);
        // Stronger than checking each holder separately: even all shares combined are covered.
        assertEq(vault.previewRedeem(modelSupply), _assetsDown(modelSupply));
        assertLe(vault.previewRedeem(modelSupply), modelAssets);
        assertLe(modelSupply, modelAssets * SafeVaultOracle.K);
    }

    function checkPreviews(uint256 assets, uint256 shares) public view {
        assertEq(vault.convertToShares(assets), _sharesDown(assets));
        assertEq(vault.previewDeposit(assets), _sharesDown(assets));
        assertEq(vault.previewWithdraw(assets), _sharesUp(assets));
        assertEq(vault.convertToAssets(shares), _assetsDown(shares));
        assertEq(vault.previewRedeem(shares), _assetsDown(shares));
        assertEq(vault.previewMint(shares), _assetsUp(shares));
    }

    /// @dev Execute every exit after a campaign, re-quoting after each burn. This catches
    /// cases where static individual quotes appear covered but later holders cannot exit.
    function drain(uint256 first) external {
        for (uint256 n; n < ACTORS; ++n) {
            uint256 i = (first % ACTORS + n) % ACTORS;
            uint256 shares = modelShares[i];
            uint256 assets = _assetsDown(shares);
            assertEq(vault.previewRedeem(shares), assets);
            vm.prank(actor(i));
            assertEq(vault.redeem(shares, actor(i), actor(i)), assets);
            _exit(i, i, assets, shares);
            checkAccounting();
        }
        assertEq(vault.totalSupply(), 0);
    }

    function _enter(uint256 payer, uint256 receiver, uint256 assets, uint256 shares) private {
        modelTokens[payer] -= assets;
        modelShares[receiver] += shares;
        modelAssets += assets;
        modelSupply += shares;
        deposited += assets;
    }

    function _exit(uint256 owner, uint256 receiver, uint256 assets, uint256 shares) private {
        modelTokens[receiver] += assets;
        modelShares[owner] -= shares;
        modelAssets -= assets;
        modelSupply -= shares;
        paidOut += assets;
    }

    function _approveExit(uint256 owner, uint256 callerSeed, uint256 shares) private {
        if (actor(owner) == actor(callerSeed)) return;
        vm.prank(actor(owner));
        vault.approve(actor(callerSeed), callerSeed & 4 == 0 ? shares : type(uint256).max);
    }

    function _checkAllowance(uint256 owner, uint256 callerSeed) private view {
        if (actor(owner) == actor(callerSeed)) return;
        assertEq(vault.allowance(actor(owner), actor(callerSeed)), callerSeed & 4 == 0 ? 0 : type(uint256).max);
    }

    function _sharesDown(uint256 assets) private view returns (uint256) {
        return SafeVaultOracle.down(assets, modelSupply + SafeVaultOracle.K, modelAssets + 1);
    }

    function _sharesUp(uint256 assets) private view returns (uint256) {
        return SafeVaultOracle.up(assets, modelSupply + SafeVaultOracle.K, modelAssets + 1);
    }

    function _assetsDown(uint256 shares) private view returns (uint256) {
        return SafeVaultOracle.down(shares, modelAssets + 1, modelSupply + SafeVaultOracle.K);
    }

    function _assetsUp(uint256 shares) private view returns (uint256) {
        return SafeVaultOracle.up(shares, modelAssets + 1, modelSupply + SafeVaultOracle.K);
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        // Preserve literal small inputs, and regularly exercise zero, one, full exits and
        // one below the limit instead of spending the whole campaign on middling amounts.
        if (seed <= maximum) return seed;
        if (seed % 8 == 0) return 0;
        if (seed % 8 == 1) return _min(1, maximum);
        if (seed % 8 == 2) return maximum;
        if (seed % 8 == 3) return maximum == 0 ? 0 : maximum - 1;
        return SafeVaultOracle.bound(seed, maximum);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
