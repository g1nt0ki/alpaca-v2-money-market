// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

interface IAVHandler {
  function totalLpBalance() external view returns (uint256);

  function onDeposit(
    address _stableToken,
    address _assetToken,
    uint256 _stableAmount,
    uint256 _assetAmount,
    uint256 _minLpAmount
  ) external returns (uint256);

  function onWithdraw(uint256 _lpToRemove) external returns (uint256, uint256);

  function setWhitelistedCallers(address[] calldata _callers, bool _isOk) external;
}
