// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal Foundry interface: no runtime dependencies, environment reads, FFI, or file access.
interface Vm {
    function prank(address caller) external;
    function startPrank(address caller) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
    function toString(uint256 value) external pure returns (string memory);
    function toString(int256 value) external pure returns (string memory);
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log(string message);

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "uint mismatch");
    }

    function assertEq(int256 actual, int256 expected) internal pure {
        require(actual == expected, "int mismatch");
    }

    function assertEq(address actual, address expected) internal pure {
        require(actual == expected, "address mismatch");
    }

    function assertLe(uint256 actual, uint256 maximum) internal pure {
        require(actual <= maximum, "above bound");
    }
}
