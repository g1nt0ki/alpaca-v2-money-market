// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// interfaces
import { IAVTradeFacet } from "../interfaces/IAVTradeFacet.sol";
import { IAVShareToken } from "../interfaces/IAVShareToken.sol";
import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

// libraries
import { LibAV01 } from "../libraries/LibAV01.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibSafeToken } from "../libraries/LibSafeToken.sol";

contract AVTradeFacet is IAVTradeFacet {
  using LibSafeToken for IERC20;

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
    LibAV01.AVDiamondStorage storage avDs = LibAV01.avDiamondStorage();

    _mintManagementFeeToTreasury(_shareToken, avDs);

    LibAV01.VaultConfig memory _vaultConfig = avDs.vaultConfigs[_shareToken];
    address _stableToken = _vaultConfig.stableToken;
    address _assetToken = _vaultConfig.assetToken;

    (uint256 _stableBorrowAmount, uint256 _assetBorrowAmount) = LibAV01.calculateBorrowAmount(
      _stableToken,
      _assetToken,
      _stableAmountIn,
      _vaultConfig.leverageLevel,
      avDs
    );

    // get fund from user
    IERC20(_stableToken).safeTransferFrom(msg.sender, address(this), _stableAmountIn);

    uint256 _equityBefore = LibAV01.getEquity(_shareToken, _vaultConfig.handler, avDs);

    // borrow from MM
    LibAV01.borrowMoneyMarket(_shareToken, _stableToken, _stableBorrowAmount, avDs);
    LibAV01.borrowMoneyMarket(_shareToken, _assetToken, _assetBorrowAmount, avDs);

    uint256 _shareToMint = LibAV01.depositToHandler(
      _vaultConfig.handler,
      _shareToken,
      _stableToken,
      _assetToken,
      _stableAmountIn + _stableBorrowAmount,
      _assetBorrowAmount,
      _equityBefore,
      avDs
    );

    if (_minShareOut > _shareToMint) revert AVTradeFacet_TooLittleReceived();

    IAVShareToken(_shareToken).mint(msg.sender, _shareToMint);

    emit LogDeposit(msg.sender, _shareToken, _stableToken, _stableAmountIn);
  }

  function withdraw(
    address _shareToken,
    uint256 _shareToWithdraw,
    uint256 _minTokenOut
  ) external nonReentrant {
    LibAV01.AVDiamondStorage storage avDs = LibAV01.avDiamondStorage();
    LibAV01.VaultConfig memory vaultConfig = avDs.vaultConfigs[_shareToken];

    _mintManagementFeeToTreasury(_shareToken, avDs);

    address _stableToken = vaultConfig.stableToken;
    uint256 _shareValueToWithdraw = LibAV01.getShareValue(_shareToken, _shareToWithdraw, avDs);

    (uint256 _stableTokenAmount, uint256 _assetTokenAmount) = LibAV01.withdrawFromHandler(
      _shareToken,
      _shareValueToWithdraw,
      avDs
    );

    (uint256 _tokenPrice, ) = LibAV01.getPriceUSD(vaultConfig.stableToken, avDs);
    uint256 _amountToReturn = (_shareValueToWithdraw * 1e18) /
      (_tokenPrice * avDs.tokenConfigs[_stableToken].to18ConversionFactor);

    if (_amountToReturn < _minTokenOut) revert AVTradeFacet_TooLittleReceived();
    if (_amountToReturn > _stableTokenAmount) revert AVTradeFacet_InsufficientAmount();

    // repay to MM
    LibAV01.repayMoneyMarket(_shareToken, vaultConfig.stableToken, _stableTokenAmount - _amountToReturn, avDs);
    LibAV01.repayMoneyMarket(_shareToken, vaultConfig.assetToken, _assetTokenAmount, avDs);

    IAVShareToken(_shareToken).burn(msg.sender, _shareToWithdraw);
    ERC20(vaultConfig.stableToken).safeTransfer(msg.sender, _amountToReturn);

    emit LogWithdraw(msg.sender, _shareToken, _shareToWithdraw, _stableToken, _amountToReturn);
  }

  function getDebtValues(address _shareToken) external view returns (uint256, uint256) {
    LibAV01.AVDiamondStorage storage avDs = LibAV01.avDiamondStorage();
    LibAV01.VaultConfig memory _config = avDs.vaultConfigs[_shareToken];
    return (
      avDs.vaultDebtValues[_shareToken][_config.stableToken],
      avDs.vaultDebtValues[_shareToken][_config.assetToken]
    );
  }

  function _mintManagementFeeToTreasury(address _shareToken, LibAV01.AVDiamondStorage storage avDs) internal {
    IAVShareToken(_shareToken).mint(avDs.treasury, pendingManagementFee(_shareToken));

    avDs.lastFeeCollectionTimestamps[_shareToken] = block.timestamp;
  }

  function pendingManagementFee(address _shareToken) public view returns (uint256 _pendingManagementFee) {
    LibAV01.AVDiamondStorage storage avDs = LibAV01.avDiamondStorage();

    uint256 _secondsFromLastCollection = block.timestamp - avDs.lastFeeCollectionTimestamps[_shareToken];
    _pendingManagementFee =
      (IERC20(_shareToken).totalSupply() *
        avDs.vaultConfigs[_shareToken].managementFeePerSec *
        _secondsFromLastCollection) /
      1e18;
  }
}
