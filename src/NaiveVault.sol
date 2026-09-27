// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20, IERC20, ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Intentionally vulnerable ERC-4626 vault for donation-attack experiments.
/// @dev Uses the actual token balance and share supply, with a 1:1 rate at zero supply.
contract NaiveVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Naive Vault Share", "nvMOCK") ERC4626(asset_) {}

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : Math.mulDiv(assets, supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : Math.mulDiv(shares, totalAssets(), supply, rounding);
    }
}
