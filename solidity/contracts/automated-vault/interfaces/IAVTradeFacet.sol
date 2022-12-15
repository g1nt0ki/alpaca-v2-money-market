// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IAVTradeFacet {
  function deposit(
    address _token0,
    address _token1,
    uint256 _amountIn,
    uint256 _minShareOut
  ) external;

  function withdraw(
    address _shareToken,
    uint256 _shareAmountIn,
    uint256 _minTokenOut
  ) external;
}
