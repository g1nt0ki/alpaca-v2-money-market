// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// interfaces
import { ILYFViewFacet } from "../interfaces/ILYFViewFacet.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

// libraries
import { LibLYF01 } from "../libraries/LibLYF01.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibUIntDoublyLinkedList } from "../libraries/LibUIntDoublyLinkedList.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";

contract LYFViewFacet is ILYFViewFacet {
  using LibUIntDoublyLinkedList for LibUIntDoublyLinkedList.List;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  function getOracle() external view returns (address) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return address(lyfDs.oracle);
  }

  function getLpTokenConfig(address _lpToken) external view returns (LibLYF01.LPConfig memory) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.lpConfigs[_lpToken];
  }

  function getLpTokenAmount(address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.lpAmounts[_lpToken];
  }

  function getLpTokenShare(address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.lpShares[_lpToken];
  }

  function getAllSubAccountCollats(address _account, uint256 _subAccountId)
    external
    view
    returns (LibDoublyLinkedList.Node[] memory)
  {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();
    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    LibDoublyLinkedList.List storage subAccountCollateralList = ds.subAccountCollats[_subAccount];
    return subAccountCollateralList.getAll();
  }

  function getTokenCollatAmount(address _token) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();
    return ds.collats[_token];
  }

  function getSubAccountTokenCollatAmount(
    address _account,
    uint256 _subAccountId,
    address _token
  ) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();
    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    return ds.subAccountCollats[_subAccount].getAmount(_token);
  }

  function getMMDebt(address _token) external view returns (uint256 _debtAmount) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    _debtAmount = lyfDs.moneyMarket.getNonCollatAccountDebt(address(this), _token);
  }

  function getDebtForLpToken(address _token, address _lpToken) external view returns (uint256, uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    LibLYF01.DebtPoolInfo memory debtPoolInfo = lyfDs.debtPoolInfos[_debtShareId];
    return (debtPoolInfo.totalShare, debtPoolInfo.totalValue);
  }

  function getTokenDebtValue(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return lyfDs.debtPoolInfos[_debtShareId].totalValue;
  }

  function getTokenDebtShare(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return lyfDs.debtPoolInfos[_debtShareId].totalShare;
  }

  function getSubAccountDebt(
    address _account,
    uint256 _subAccountId,
    address _token,
    address _lpToken
  ) external view returns (uint256 _debtShare, uint256 _debtAmount) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    LibLYF01.DebtPoolInfo memory debtPoolInfo = lyfDs.debtPoolInfos[_debtShareId];

    _debtShare = lyfDs.subAccountDebtShares[_subAccount].getAmount(_debtShareId);
    _debtAmount = LibShareUtil.shareToValue(_debtShare, debtPoolInfo.totalValue, debtPoolInfo.totalShare);
  }

  function getAllSubAccountDebtShares(address _account, uint256 _subAccountId)
    external
    view
    returns (LibUIntDoublyLinkedList.Node[] memory)
  {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    LibUIntDoublyLinkedList.List storage subAccountDebtShares = lyfDs.subAccountDebtShares[_subAccount];

    return subAccountDebtShares.getAll();
  }

  function getDebtLastAccrueTime(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    return lyfDs.debtPoolInfos[_debtShareId].lastAccrueAt;
  }

  function getPendingInterest(address _token, address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];
    LibLYF01.DebtPoolInfo memory debtPoolInfo = lyfDs.debtPoolInfos[_debtShareId];
    return
      LibLYF01.getDebtSharePendingInterest(
        lyfDs.moneyMarket,
        debtPoolInfo.interestModel,
        debtPoolInfo.token,
        block.timestamp - debtPoolInfo.lastAccrueAt,
        debtPoolInfo.totalValue
      );
  }

  function getPendingReward(address _lpToken) external view returns (uint256) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    return lyfDs.pendingRewards[_lpToken];
  }

  function getTotalBorrowingPower(address _account, uint256 _subAccountId)
    external
    view
    returns (uint256 _totalBorrowingPowerUSDValue)
  {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    _totalBorrowingPowerUSDValue = LibLYF01.getTotalBorrowingPower(_subAccount, lyfDs);
  }

  function getTotalUsedBorrowingPower(address _account, uint256 _subAccountId)
    external
    view
    returns (uint256 _totalBorrowedUSDValue)
  {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    _totalBorrowedUSDValue = LibLYF01.getTotalUsedBorrowingPower(_subAccount, lyfDs);
  }

  function getMaxNumOfToken() external view returns (uint8 _maxNumOfCollat) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    _maxNumOfCollat = lyfDs.maxNumOfCollatPerSubAccount;
  }

  function getMinDebtSize() external view returns (uint256 _minDebtSize) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    _minDebtSize = lyfDs.minDebtSize;
  }

  function getOutstandingBalanceOf(address _token) external view returns (uint256 _reserveAmount) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();
    if (lyfDs.reserves[_token] > lyfDs.protocolReserves[_token]) {
      _reserveAmount = lyfDs.reserves[_token] - lyfDs.protocolReserves[_token];
    }
  }

  function getProtocolReserveOf(address _token) external view returns (uint256 _protocolReserveAmount) {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    _protocolReserveAmount = lyfDs.protocolReserves[_token];
  }

  function getSubAccount(address _primary, uint256 _subAccountId) external pure returns (address _subAccount) {
    _subAccount = LibLYF01.getSubAccount(_primary, _subAccountId);
  }
}
