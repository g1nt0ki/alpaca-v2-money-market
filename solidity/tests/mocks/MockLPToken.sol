// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

contract MockLPToken {
  address public token0;
  address public token1;

  constructor(address _token0, address _token1) {
    token0 = _token0;
    token1 = _token1;
  }

  function getReserves() external pure returns (uint256, uint256) {
    return (1e30, 1e30);
  }
}
