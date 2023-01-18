// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// libs
import { LibLYF01 } from "../libraries/LibLYF01.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";

// interfaces
import { ILYFCollateralFacet } from "../interfaces/ILYFCollateralFacet.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IMasterChefLike } from "../interfaces/IMasterChefLike.sol";

contract LYFCollateralFacet is ILYFCollateralFacet {
  using LibSafeToken for IERC20;
  using LibDoublyLinkedList for LibDoublyLinkedList.List;

  event LogAddCollateral(address indexed _subAccount, address indexed _token, uint256 _amount);

  event LogRemoveCollateral(address indexed _subAccount, address indexed _token, uint256 _amount);

  event LogTransferCollateral(
    address indexed _fromSubAccount,
    address indexed _toSubAccount,
    address indexed _token,
    uint256 _amount
  );

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  function addCollateral(
    address _account,
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    if (_amount + lyfDs.collats[_token] > lyfDs.tokenConfigs[_token].maxCollateral) {
      revert LYFCollateralFacet_ExceedCollateralLimit();
    }

    address _subAccount = LibLYF01.getSubAccount(_account, _subAccountId);

    IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

    LibLYF01.addCollat(_subAccount, _token, _amount, lyfDs);

    if (lyfDs.tokenConfigs[_token].tier == LibLYF01.AssetTier.LP) {
      LibLYF01.depositToMasterChef(_token, lyfDs.lpConfigs[_token].masterChef, lyfDs.lpConfigs[_token].poolId, _amount);
    }

    emit LogAddCollateral(_subAccount, _token, _amount);
  }

  function removeCollateral(
    uint256 _subAccountId,
    address _token,
    uint256 _amount
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    address _subAccount = LibLYF01.getSubAccount(msg.sender, _subAccountId);

    LibLYF01.accrueAllDebtSharesOfSubAccount(_subAccount, lyfDs);

    uint256 _actualAmountRemoved = LibLYF01.removeCollateral(_subAccount, _token, _amount, lyfDs);

    // violate check-effect pattern for gas optimization, will change after come up with a way that doesn't loop
    if (!LibLYF01.isSubaccountHealthy(_subAccount, lyfDs)) {
      revert LYFCollateralFacet_BorrowingPowerTooLow();
    }

    if (lyfDs.tokenConfigs[_token].tier == LibLYF01.AssetTier.LP) {
      IMasterChefLike(lyfDs.lpConfigs[_token].masterChef).withdraw(
        lyfDs.lpConfigs[_token].poolId,
        _actualAmountRemoved
      );
    }

    IERC20(_token).safeTransfer(msg.sender, _actualAmountRemoved);

    emit LogRemoveCollateral(_subAccount, _token, _actualAmountRemoved);
  }

  function transferCollateral(
    uint256 _fromSubAccountId,
    uint256 _toSubAccountId,
    address _token,
    uint256 _amount
  ) external nonReentrant {
    LibLYF01.LYFDiamondStorage storage ds = LibLYF01.lyfDiamondStorage();

    address _fromSubAccount = LibLYF01.getSubAccount(msg.sender, _fromSubAccountId);

    LibLYF01.accrueAllDebtSharesOfSubAccount(_fromSubAccount, ds);

    uint256 _actualAmountRemove = LibLYF01.removeCollateral(_fromSubAccount, _token, _amount, ds);

    if (!LibLYF01.isSubaccountHealthy(_fromSubAccount, ds)) {
      revert LYFCollateralFacet_BorrowingPowerTooLow();
    }

    address _toSubAccount = LibLYF01.getSubAccount(msg.sender, _toSubAccountId);

    LibLYF01.accrueAllDebtSharesOfSubAccount(_toSubAccount, ds);

    LibLYF01.addCollat(_toSubAccount, _token, _actualAmountRemove, ds);

    emit LogTransferCollateral(_fromSubAccount, _toSubAccount, _token, _actualAmountRemove);
  }
}
