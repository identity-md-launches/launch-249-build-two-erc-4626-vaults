// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20, IERC20, ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice OpenZeppelin ERC-4626 vault with one virtual asset and 10**offset virtual shares.
/// @dev Offset 6 is recommended for this experiment. The underlying asset is the 18-decimal MockToken.
contract SafeVault is ERC4626 {
    error InvalidDecimalsOffset(uint8 offset);

    uint8 public immutable decimalsOffset;

    constructor(IERC20 asset_, uint8 offset_) ERC20("Safe Vault Share", "svMOCK") ERC4626(asset_) {
        if (offset_ > 18) revert InvalidDecimalsOffset(offset_);
        decimalsOffset = offset_;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return decimalsOffset;
    }
}
