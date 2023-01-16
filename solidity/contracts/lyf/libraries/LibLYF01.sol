// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

// libs
import { LibDoublyLinkedList } from "./LibDoublyLinkedList.sol";
import { LibUIntDoublyLinkedList } from "./LibUIntDoublyLinkedList.sol";
import { LibFullMath } from "./LibFullMath.sol";
import { LibShareUtil } from "./LibShareUtil.sol";
import { LibSafeToken } from "./LibSafeToken.sol";

// interfaces
import { IAlpacaV2Oracle } from "../interfaces/IAlpacaV2Oracle.sol";
import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IMasterChefLike } from "../interfaces/IMasterChefLike.sol";
import { IRouterLike } from "../interfaces/IRouterLike.sol";
import { ISwapPairLike } from "../interfaces/ISwapPairLike.sol";
import { IStrat } from "../interfaces/IStrat.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

library LibLYF01 {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  using LibUIntDoublyLinkedList for LibUIntDoublyLinkedList.List;
  using LibSafeToken for IERC20;

  // keccak256("lyf.diamond.storage");
  bytes32 internal constant LYF_STORAGE_POSITION = 0x23ec0f04376c11672050f8fa65aa7cdd1b6edcb0149eaae973a7060e7ef8f3f4;

  uint256 internal constant MAX_BPS = 10000;

  event LogAccrueInterest(address indexed _token, uint256 _totalInterest, uint256 _totalToProtocolReserve);
  event LogReinvest(address indexed _rewardTo, uint256 _reward, uint256 _bounty);

  error LibLYF01_BadSubAccountId();
  error LibLYF01_PriceStale(address);
  error LibLYF01_UnsupportedDecimals();
  error LibLYF01_NumberOfTokenExceedLimit();
  error LibLYF01_BorrowLessThanMinDebtSize();

  enum AssetTier {
    UNLISTED,
    COLLATERAL,
    LP
  }

  struct TokenConfig {
    LibLYF01.AssetTier tier;
    uint16 collateralFactor;
    uint16 borrowingFactor;
    uint64 to18ConversionFactor;
    uint256 maxCollateral;
    uint256 maxBorrow;
  }

  struct LPConfig {
    address strategy;
    address masterChef;
    address router;
    address rewardToken;
    address[] reinvestPath;
    uint256 poolId;
    uint256 reinvestThreshold;
  }

  // Storage
  struct LYFDiamondStorage {
    address moneyMarket;
    address treasury;
    address oracle;
    mapping(address => uint256) reserves;
    mapping(address => uint256) protocolReserves;
    // collats = amount of collateral token
    mapping(address => uint256) collats;
    mapping(address => LibDoublyLinkedList.List) subAccountCollats;
    mapping(address => TokenConfig) tokenConfigs;
    // token => lp token => debt share id
    mapping(address => mapping(address => uint256)) debtShareIds;
    mapping(uint256 => address) debtShareTokens;
    mapping(address => LibUIntDoublyLinkedList.List) subAccountDebtShares;
    mapping(uint256 => uint256) debtShares;
    mapping(uint256 => uint256) debtValues;
    mapping(uint256 => uint256) debtLastAccrueTime;
    mapping(address => uint256) lpShares;
    mapping(address => uint256) lpAmounts;
    mapping(address => LPConfig) lpConfigs;
    mapping(uint256 => address) interestModels;
    mapping(address => uint256) pendingRewards;
    mapping(address => bool) reinvestorsOk;
    mapping(address => bool) liquidationStratOk;
    mapping(address => bool) liquidationCallersOk;
    uint8 maxNumOfCollatPerSubAccount;
    uint256 minDebtSize;
  }

  function lyfDiamondStorage() internal pure returns (LYFDiamondStorage storage lyfStorage) {
    assembly {
      lyfStorage.slot := LYF_STORAGE_POSITION
    }
  }

  function getSubAccount(address primary, uint256 subAccountId) internal pure returns (address) {
    if (subAccountId > 255) {
      revert LibLYF01_BadSubAccountId();
    }
    return address(uint160(primary) ^ uint160(subAccountId));
  }

  function setTokenConfig(
    address _token,
    TokenConfig memory _config,
    LYFDiamondStorage storage lyfDs
  ) internal {
    lyfDs.tokenConfigs[_token] = _config;
  }

  function pendingInterest(uint256 _debtShareId, LYFDiamondStorage storage lyfDs)
    internal
    view
    returns (uint256 _pendingInterest)
  {
    uint256 _lastAccrueTime = lyfDs.debtLastAccrueTime[_debtShareId];
    if (block.timestamp > _lastAccrueTime) {
      uint256 _timePast = block.timestamp - _lastAccrueTime;
      address _interestModel = address(lyfDs.interestModels[_debtShareId]);
      if (_interestModel != address(0)) {
        address _token = lyfDs.debtShareTokens[_debtShareId];
        uint256 _debtValue = IMoneyMarket(lyfDs.moneyMarket).getGlobalDebtValue(_token);
        uint256 _floating = IMoneyMarket(lyfDs.moneyMarket).getFloatingBalance(_token);
        uint256 _interestRate = IInterestRateModel(_interestModel).getInterestRate(_debtValue, _floating);

        _pendingInterest = (_interestRate * _timePast * lyfDs.debtValues[_debtShareId]) / 1e18;
      }
    }
  }

  function accrueInterest(uint256 _debtShareId, LYFDiamondStorage storage lyfDs) internal {
    uint256 _pendingInterest = pendingInterest(_debtShareId, lyfDs);
    if (_pendingInterest > 0) {
      // update debt
      lyfDs.debtValues[_debtShareId] += _pendingInterest;
      lyfDs.protocolReserves[lyfDs.debtShareTokens[_debtShareId]] += _pendingInterest;
    }
    // update timestamp
    lyfDs.debtLastAccrueTime[_debtShareId] = block.timestamp;

    // TODO: move emit into if ?
    emit LogAccrueInterest(lyfDs.debtShareTokens[_debtShareId], _pendingInterest, _pendingInterest);
  }

  function accrueAllSubAccountDebtShares(address _subAccount, LYFDiamondStorage storage lyfDs) internal {
    LibUIntDoublyLinkedList.Node[] memory _debtShares = lyfDs.subAccountDebtShares[_subAccount].getAll();
    uint256 _debtShareLength = _debtShares.length;

    for (uint256 _i; _i < _debtShareLength; ) {
      accrueInterest(_debtShares[_i].index, lyfDs);
      unchecked {
        ++_i;
      }
    }
  }

  function getTotalBorrowingPower(address _subAccount, LYFDiamondStorage storage lyfDs)
    internal
    view
    returns (uint256 _totalBorrowingPowerUSDValue)
  {
    LibDoublyLinkedList.Node[] memory _collats = lyfDs.subAccountCollats[_subAccount].getAll();

    uint256 _collatsLength = _collats.length;
    uint256 _tokenPrice;
    address _collatToken;
    uint256 _collatAmount;
    uint256 _actualAmount;
    for (uint256 _i; _i < _collatsLength; ) {
      _collatToken = _collats[_i].token;
      _collatAmount = _collats[_i].amount;
      _actualAmount = _collatAmount;

      // will return address(0) if _collatToken is not ibToken
      address _actualToken = IMoneyMarket(lyfDs.moneyMarket).getTokenFromIbToken(_collatToken);
      if (_actualToken == address(0)) {
        _actualToken = _collatToken;
      } else {
        uint256 _totalSupply = IERC20(_collatToken).totalSupply();
        uint256 _totalToken = IMoneyMarket(lyfDs.moneyMarket).getTotalTokenWithPendingInterest(_actualToken);

        _actualAmount = LibShareUtil.shareToValue(_collatAmount, _totalToken, _totalSupply);
      }

      TokenConfig memory _tokenConfig = lyfDs.tokenConfigs[_actualToken];

      _tokenPrice = getPriceUSD(_actualToken, lyfDs);

      // _totalBorrowingPowerUSDValue += amount * tokenPrice * collateralFactor
      _totalBorrowingPowerUSDValue += LibFullMath.mulDiv(
        _actualAmount * _tokenConfig.to18ConversionFactor * _tokenConfig.collateralFactor,
        _tokenPrice,
        1e22
      );

      unchecked {
        ++_i;
      }
    }
  }

  function getTotalUsedBorrowingPower(address _subAccount, LYFDiamondStorage storage lyfDs)
    internal
    view
    returns (uint256 _totalUsedBorrowingPower)
  {
    LibUIntDoublyLinkedList.Node[] memory _borrowed = lyfDs.subAccountDebtShares[_subAccount].getAll();

    uint256 _borrowedLength = _borrowed.length;
    uint256 _tokenPrice;
    for (uint256 _i; _i < _borrowedLength; ) {
      address _debtToken = lyfDs.debtShareTokens[_borrowed[_i].index];
      TokenConfig memory _tokenConfig = lyfDs.tokenConfigs[_debtToken];
      _tokenPrice = getPriceUSD(_debtToken, lyfDs);
      uint256 _borrowedAmount = LibShareUtil.shareToValue(
        _borrowed[_i].amount,
        lyfDs.debtValues[_borrowed[_i].index],
        lyfDs.debtShares[_borrowed[_i].index]
      );
      _totalUsedBorrowingPower += usedBorrowingPower(_borrowedAmount, _tokenPrice, _tokenConfig.borrowingFactor);
      unchecked {
        ++_i;
      }
    }
  }

  function getTotalBorrowedUSDValue(address _subAccount, LYFDiamondStorage storage lyfDs)
    internal
    view
    returns (uint256 _totalBorrowedUSDValue)
  {
    LibUIntDoublyLinkedList.Node[] memory _borrowed = lyfDs.subAccountDebtShares[_subAccount].getAll();

    uint256 _borrowedLength = _borrowed.length;
    uint256 _tokenPrice;
    uint256 _borrowedAmount;
    address _debtToken;
    for (uint256 _i; _i < _borrowedLength; ) {
      _debtToken = lyfDs.debtShareTokens[_borrowed[_i].index];
      _tokenPrice = getPriceUSD(_debtToken, lyfDs);
      _borrowedAmount = LibShareUtil.shareToValue(
        _borrowed[_i].amount,
        lyfDs.debtValues[_borrowed[_i].index],
        lyfDs.debtShares[_borrowed[_i].index]
      );

      TokenConfig memory _tokenConfig = lyfDs.tokenConfigs[_debtToken];
      // _totalBorrowedUSDValue += _borrowedAmount * tokenPrice
      _totalBorrowedUSDValue += LibFullMath.mulDiv(
        _borrowedAmount * _tokenConfig.to18ConversionFactor,
        _tokenPrice,
        1e18
      );

      unchecked {
        ++_i;
      }
    }
  }

  function getPriceUSD(address _token, LYFDiamondStorage storage lyfDs) internal view returns (uint256 _price) {
    if (lyfDs.tokenConfigs[_token].tier == AssetTier.LP) {
      (_price, ) = IAlpacaV2Oracle(lyfDs.oracle).lpToDollar(1e18, _token);
    } else {
      (_price, ) = IAlpacaV2Oracle(lyfDs.oracle).getTokenPrice(_token);
    }
  }

  function getIbPriceUSD(
    address _ibToken,
    address _token,
    LYFDiamondStorage storage lyfDs
  ) internal view returns (uint256) {
    uint256 _underlyingTokenPrice = getPriceUSD(_token, lyfDs);
    uint256 _totalSupply = IERC20(_ibToken).totalSupply();
    uint256 _one = 10**IERC20(_ibToken).decimals();

    uint256 _totalToken = IMoneyMarket(lyfDs.moneyMarket).getTotalTokenWithPendingInterest(_token);
    uint256 _ibValue = LibShareUtil.shareToValue(_one, _totalToken, _totalSupply);

    uint256 _price = (_underlyingTokenPrice * _ibValue) / _one;
    return (_price);
  }

  // _usedBorrowingPower += _borrowedAmount * tokenPrice * (10000/ borrowingFactor)
  function usedBorrowingPower(
    uint256 _borrowedAmount,
    uint256 _tokenPrice,
    uint256 _borrowingFactor
  ) internal pure returns (uint256 _usedBorrowingPower) {
    _usedBorrowingPower = LibFullMath.mulDiv(_borrowedAmount * MAX_BPS, _tokenPrice, 1e18 * uint256(_borrowingFactor));
  }

  function addCollat(
    address _subAccount,
    address _token,
    uint256 _amount,
    LYFDiamondStorage storage lyfDs
  ) internal returns (uint256 _amountAdded) {
    // update subaccount state
    LibDoublyLinkedList.List storage subAccountCollateralList = lyfDs.subAccountCollats[_subAccount];
    if (subAccountCollateralList.getNextOf(LibDoublyLinkedList.START) == LibDoublyLinkedList.EMPTY) {
      subAccountCollateralList.init();
    }
    uint256 _currentAmount = subAccountCollateralList.getAmount(_token);

    _amountAdded = _amount;
    // If collat is LP take collat as a share, not direct amount
    if (lyfDs.tokenConfigs[_token].tier == AssetTier.LP) {
      reinvest(_token, lyfDs.lpConfigs[_token].reinvestThreshold, lyfDs.lpConfigs[_token], lyfDs);

      _amountAdded = LibShareUtil.valueToShareRoundingUp(_amount, lyfDs.lpShares[_token], lyfDs.lpAmounts[_token]);

      // update lp global state
      lyfDs.lpShares[_token] += _amountAdded;
      lyfDs.lpAmounts[_token] += _amount;
    }

    subAccountCollateralList.addOrUpdate(_token, _currentAmount + _amountAdded);
    if (subAccountCollateralList.length() > lyfDs.maxNumOfCollatPerSubAccount) {
      revert LibLYF01_NumberOfTokenExceedLimit();
    }

    lyfDs.collats[_token] += _amount;
  }

  function removeCollateral(
    address _subAccount,
    address _token,
    uint256 _removeAmount,
    LYFDiamondStorage storage ds
  ) internal returns (uint256 _amountRemoved) {
    LibDoublyLinkedList.List storage _subAccountCollatList = ds.subAccountCollats[_subAccount];

    uint256 _collateralAmount = _subAccountCollatList.getAmount(_token);
    if (_collateralAmount > 0) {
      _amountRemoved = _removeAmount > _collateralAmount ? _collateralAmount : _removeAmount;

      _subAccountCollatList.updateOrRemove(_token, _collateralAmount - _amountRemoved);

      // If LP token, handle extra step
      if (ds.tokenConfigs[_token].tier == AssetTier.LP) {
        reinvest(_token, ds.lpConfigs[_token].reinvestThreshold, ds.lpConfigs[_token], ds);

        uint256 _lpValueRemoved = LibShareUtil.shareToValue(_amountRemoved, ds.lpAmounts[_token], ds.lpShares[_token]);

        ds.lpShares[_token] -= _amountRemoved;
        ds.lpAmounts[_token] -= _lpValueRemoved;

        // _amountRemoved used to represent lpShare, we need to return lpValue so re-assign it here
        _amountRemoved = _lpValueRemoved;
      }

      ds.collats[_token] -= _amountRemoved;
    }
  }

  function removeIbCollateral(
    address _subAccount,
    address _token,
    address _ibToken,
    uint256 _removeAmountUnderlying,
    LYFDiamondStorage storage ds
  ) internal returns (uint256 _underlyingRemoved) {
    if (_ibToken == address(0) || _removeAmountUnderlying == 0) {
      return 0;
    }

    LibDoublyLinkedList.List storage _subAccountCollatList = ds.subAccountCollats[_subAccount];

    uint256 _collateralAmountIb = _subAccountCollatList.getAmount(_ibToken);

    if (_collateralAmountIb > 0) {
      IMoneyMarket moneyMarket = IMoneyMarket(ds.moneyMarket);

      uint256 _removeAmountIb = moneyMarket.getIbShareFromUnderlyingAmount(_token, _removeAmountUnderlying);
      uint256 _ibRemoved = _removeAmountIb > _collateralAmountIb ? _collateralAmountIb : _removeAmountIb;

      _subAccountCollatList.updateOrRemove(_ibToken, _collateralAmountIb - _ibRemoved);

      _underlyingRemoved = moneyMarket.withdraw(_ibToken, _ibRemoved);

      ds.collats[_ibToken] -= _ibRemoved;
    }
  }

  function isSubaccountHealthy(address _subAccount, LYFDiamondStorage storage ds) internal view returns (bool) {
    uint256 _totalBorrowingPower = getTotalBorrowingPower(_subAccount, ds);
    uint256 _totalUsedBorrowingPower = getTotalUsedBorrowingPower(_subAccount, ds);
    return _totalBorrowingPower >= _totalUsedBorrowingPower;
  }

  function validateMinDebtSize(
    address _subAccount,
    uint256 _debtShareId,
    LYFDiamondStorage storage lyfDs
  ) internal view {
    (uint256 _debtShare, uint256 _debtAmount) = getDebt(_subAccount, _debtShareId, lyfDs);
    if (_debtShare != 0) {
      address _debtToken = lyfDs.debtShareTokens[_debtShareId];
      uint256 _tokenPrice = getPriceUSD(_debtToken, lyfDs);

      if (
        LibFullMath.mulDiv(_debtAmount * lyfDs.tokenConfigs[_debtToken].to18ConversionFactor, _tokenPrice, 1e18) <
        lyfDs.minDebtSize
      ) {
        revert LibLYF01_BorrowLessThanMinDebtSize();
      }
    }
  }

  function to18ConversionFactor(address _token) internal view returns (uint64) {
    uint256 _decimals = IERC20(_token).decimals();
    if (_decimals > 18) {
      revert LibLYF01_UnsupportedDecimals();
    }
    uint256 _conversionFactor = 10**(18 - _decimals);
    return uint64(_conversionFactor);
  }

  function depositToMasterChef(
    address _lpToken,
    address _masterChef,
    uint256 _poolId,
    uint256 _amount
  ) internal {
    IERC20(_lpToken).safeIncreaseAllowance(_masterChef, _amount);
    IMasterChefLike(_masterChef).deposit(_poolId, _amount);
  }

  function harvest(
    address _lpToken,
    LibLYF01.LPConfig memory _lpConfig,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    uint256 _rewardBefore = IERC20(_lpConfig.rewardToken).balanceOf(address(this));

    IMasterChefLike(_lpConfig.masterChef).withdraw(_lpConfig.poolId, 0);

    // accumulate harvested reward for LP
    lyfDs.pendingRewards[_lpToken] += IERC20(_lpConfig.rewardToken).balanceOf(address(this)) - _rewardBefore;
  }

  function reinvest(
    address _lpToken,
    uint256 _reinvestThreshold,
    LibLYF01.LPConfig memory _lpConfig,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    harvest(_lpToken, _lpConfig, lyfDs);

    uint256 _rewardAmount = lyfDs.pendingRewards[_lpToken];
    if (_rewardAmount < _reinvestThreshold) {
      return;
    }

    // TODO: extract fee

    address _token0 = ISwapPairLike(_lpToken).token0();
    address _token1 = ISwapPairLike(_lpToken).token1();

    // convert rewardToken to either token0 or token1
    uint256 _reinvestAmount;
    if (_lpConfig.rewardToken == _token0 || _lpConfig.rewardToken == _token1) {
      _reinvestAmount = _rewardAmount;
    } else {
      IERC20(_lpConfig.rewardToken).safeIncreaseAllowance(_lpConfig.router, _rewardAmount);
      uint256[] memory _amounts = IRouterLike(_lpConfig.router).swapExactTokensForTokens(
        _rewardAmount,
        0,
        _lpConfig.reinvestPath,
        address(this),
        block.timestamp
      );
      _reinvestAmount = _amounts[_amounts.length - 1];
    }

    uint256 _token0Amount;
    uint256 _token1Amount;
    address _reinvestToken = _lpConfig.reinvestPath[_lpConfig.reinvestPath.length - 1];

    if (_reinvestToken == _token0) {
      _token0Amount = _reinvestAmount;
    } else {
      _token1Amount = _reinvestAmount;
    }

    IERC20(_token0).safeTransfer(_lpConfig.strategy, _token0Amount);
    IERC20(_token1).safeTransfer(_lpConfig.strategy, _token1Amount);
    uint256 _lpReceived = IStrat(_lpConfig.strategy).composeLPToken(
      _token0,
      _token1,
      _lpToken,
      _token0Amount,
      _token1Amount,
      0
    );

    // deposit lp back to masterChef
    lyfDs.lpAmounts[_lpToken] += _lpReceived;
    lyfDs.collats[_lpToken] += _lpReceived;
    depositToMasterChef(_lpToken, _lpConfig.masterChef, _lpConfig.poolId, _lpReceived);

    // reset pending reward
    lyfDs.pendingRewards[_lpToken] = 0;

    // TODO: assign param properly
    emit LogReinvest(msg.sender, 0, 0);
  }

  function getDebt(
    address _subAccount,
    uint256 _debtShareId,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal view returns (uint256 _debtShare, uint256 _debtAmount) {
    _debtShare = lyfDs.subAccountDebtShares[_subAccount].getAmount(_debtShareId);
    // Note: precision loss 1 wei when convert share back to value
    _debtAmount = LibShareUtil.shareToValue(_debtShare, lyfDs.debtValues[_debtShareId], lyfDs.debtShares[_debtShareId]);
  }

  function borrowFromMoneyMarket(
    address _subAccount,
    address _token,
    address _lpToken,
    uint256 _amount,
    LibLYF01.LYFDiamondStorage storage lyfDs
  ) internal {
    if (_amount == 0) return;
    uint256 _debtShareId = lyfDs.debtShareIds[_token][_lpToken];

    IMoneyMarket(lyfDs.moneyMarket).nonCollatBorrow(_token, _amount);

    LibUIntDoublyLinkedList.List storage userDebtShare = lyfDs.subAccountDebtShares[_subAccount];

    if (
      lyfDs.subAccountDebtShares[_subAccount].getNextOf(LibUIntDoublyLinkedList.START) == LibUIntDoublyLinkedList.EMPTY
    ) {
      lyfDs.subAccountDebtShares[_subAccount].init();
    }

    uint256 _totalSupply = lyfDs.debtShares[_debtShareId];
    uint256 _totalValue = lyfDs.debtValues[_debtShareId];

    uint256 _shareToAdd = LibShareUtil.valueToShareRoundingUp(_amount, _totalSupply, _totalValue);

    // update over collat debt
    lyfDs.debtShares[_debtShareId] += _shareToAdd;
    lyfDs.debtValues[_debtShareId] += _amount;

    uint256 _newShareAmount = userDebtShare.getAmount(_debtShareId) + _shareToAdd;

    // update user's debtshare
    userDebtShare.addOrUpdate(_debtShareId, _newShareAmount);
  }
}
