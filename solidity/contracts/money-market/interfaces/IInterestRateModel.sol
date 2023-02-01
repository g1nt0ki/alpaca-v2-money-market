// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

interface IInterestRateModel {
  function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256);
}
