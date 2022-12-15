// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// interfaces
import { IAVTradeFacet } from "../interfaces/IAVTradeFacet.sol";
import { IAVShareToken } from "../interfaces/IAVShareToken.sol";
import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";

// libraries
import { LibAV01 } from "../libraries/LibAV01.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";

contract AVTradeFacet is IAVTradeFacet {
  using SafeERC20 for ERC20;

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  function deposit(
    address _shareToken,
    uint256 _stableAmountIn,
    uint256 _minShareOut
  ) external nonReentrant {
    LibAV01.AVDiamondStorage storage avDs = LibAV01.getStorage();
    LibAV01.VaultConfig memory vaultConfig = avDs.vaultConfigs[_shareToken];
    address _stableToken = vaultConfig.stableToken;
    address _assetToken = vaultConfig.assetToken;

    (uint256 _stableBorrowAmount, uint256 _assetBorrowAmount) = LibAV01.calculateBorrowAmount(
      _stableToken,
      _assetToken,
      _stableAmountIn,
      vaultConfig.leverageLevel,
      avDs
    );

    ERC20(_stableToken).safeTransferFrom(msg.sender, address(this), _stableAmountIn);
    LibAV01.borrowMoneyMarket(_shareToken, _stableToken, _stableBorrowAmount, avDs);
    LibAV01.borrowMoneyMarket(_shareToken, _assetToken, _assetBorrowAmount, avDs);

    uint256 _shareToMint = LibAV01.deposit(
      _shareToken,
      _stableToken,
      _assetToken,
      _stableAmountIn + _stableBorrowAmount,
      _assetBorrowAmount,
      _minShareOut,
      avDs
    );

    IAVShareToken(_shareToken).mint(msg.sender, _shareToMint);

    emit LogDeposit(msg.sender, _shareToken, _stableToken, _stableAmountIn);
  }

  function withdraw(
    address _shareToken,
    uint256 _shareAmountIn,
    uint256 _minTokenOut
  ) external nonReentrant {
    LibAV01.AVDiamondStorage storage avDs = LibAV01.getStorage();
    LibAV01.withdraw(_shareToken, _shareAmountIn, _minTokenOut, avDs);
  }
}
