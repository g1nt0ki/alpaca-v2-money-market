// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// libraries
import { LibMoneyMarket01 } from "../libraries/LibMoneyMarket01.sol";
import { LibDoublyLinkedList } from "../libraries/LibDoublyLinkedList.sol";
import { LibShareUtil } from "../libraries/LibShareUtil.sol";
import { LibReentrancyGuard } from "../libraries/LibReentrancyGuard.sol";

// interfaces
import { ILiquidationFacet } from "../interfaces/ILiquidationFacet.sol";
import { IIbToken } from "../interfaces/IIbToken.sol";
import { ILiquidationStrategy } from "../interfaces/ILiquidationStrategy.sol";
import { ILendFacet } from "../interfaces/ILendFacet.sol";

import { console } from "solidity/tests/utils/console.sol";

contract LiquidationFacet is ILiquidationFacet {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  using SafeERC20 for ERC20;

  uint256 constant REPURCHASE_REWARD_BPS = 100;
  uint256 constant LIQUIDATION_REWARD_BPS = 100;
  uint256 constant LIQUIDATION_FEE_BPS = 100;

  modifier nonReentrant() {
    LibReentrancyGuard.lock();
    _;
    LibReentrancyGuard.unlock();
  }

  function repurchase(
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    uint256 _repayAmount
  ) external nonReentrant returns (uint256 _collatAmountOut) {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    if (!moneyMarketDs.repurchasersOk[msg.sender]) {
      revert LiquidationFacet_Unauthorized();
    }

    address _subAccount = LibMoneyMarket01.getSubAccount(_account, _subAccountId);

    LibMoneyMarket01.accureAllSubAccountDebtToken(_subAccount, moneyMarketDs);

    uint256 _borrowingPower = LibMoneyMarket01.getTotalBorrowingPower(_subAccount, moneyMarketDs);
    uint256 _borrowedValue = LibMoneyMarket01.getTotalBorrowedUSDValue(_subAccount, moneyMarketDs);

    if (_borrowingPower > _borrowedValue) {
      revert LiquidationFacet_Healthy();
    }

    uint256 _actualRepayAmount = _getActualRepayAmount(_subAccount, _repayToken, _repayAmount, moneyMarketDs);
    (uint256 _repayTokenPrice, ) = LibMoneyMarket01.getPriceUSD(_repayToken, moneyMarketDs);
    LibMoneyMarket01.TokenConfig memory _repayTokenConfig = moneyMarketDs.tokenConfigs[_repayToken];

    uint256 _repayInUSD = (_actualRepayAmount * _repayTokenConfig.to18ConversionFactor * _repayTokenPrice) / 1e18;
    // todo: tbd
    if (_repayInUSD * 2 > _borrowedValue) {
      revert LiquidationFacet_RepayDebtValueTooHigh();
    }

    // calculate collateral amount that repurchaser will receive
    _collatAmountOut = _getCollatAmountOut(
      _subAccount,
      _collatToken,
      _repayInUSD,
      REPURCHASE_REWARD_BPS,
      moneyMarketDs
    );

    _reduceDebt(_subAccount, _repayToken, _actualRepayAmount, moneyMarketDs);
    _reduceCollateral(_subAccount, _collatToken, _collatAmountOut, moneyMarketDs);

    ERC20(_repayToken).safeTransferFrom(msg.sender, address(this), _actualRepayAmount);
    ERC20(_collatToken).safeTransfer(msg.sender, _collatAmountOut);

    emit LogRepurchase(msg.sender, _repayToken, _collatToken, _repayAmount, _collatAmountOut);
  }

  function liquidationCall(
    address _liquidationStrat,
    address _account,
    uint256 _subAccountId,
    address _repayToken,
    address _collatToken,
    uint256 _repayAmount
  ) external nonReentrant {
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs = LibMoneyMarket01.moneyMarketDiamondStorage();

    if (!moneyMarketDs.liquidationStratOk[_liquidationStrat] || !moneyMarketDs.liquidationCallersOk[msg.sender]) {
      revert LiquidationFacet_Unauthorized();
    }

    address _subAccount = LibMoneyMarket01.getSubAccount(_account, _subAccountId);

    LibMoneyMarket01.accureAllSubAccountDebtToken(_subAccount, moneyMarketDs);

    // 1. check if position is underwater and can be liquidated
    {
      uint256 _borrowingPower = LibMoneyMarket01.getTotalBorrowingPower(_subAccount, moneyMarketDs);
      (uint256 _usedBorrowingPower, ) = LibMoneyMarket01.getTotalUsedBorrowedPower(_subAccount, moneyMarketDs);
      if ((_borrowingPower * 10000) > _usedBorrowingPower * 9000) {
        revert LiquidationFacet_Healthy();
      }
    }

    address _collatUnderlyingToken = moneyMarketDs.ibTokenToTokens[_collatToken];
    // handle liqudiate ib as collat
    if (_collatUnderlyingToken != address(0)) {
      _ibLiquidationCall(
        _liquidationStrat,
        _subAccount,
        _repayToken,
        _collatToken,
        _collatUnderlyingToken,
        _repayAmount,
        moneyMarketDs
      );
    } else {
      _liquidationCall(_liquidationStrat, _subAccount, _repayToken, _collatToken, _repayAmount, moneyMarketDs);
    }
  }

  function _liquidationCall(
    address _liquidationStrat,
    address _subAccount,
    address _repayToken,
    address _collatToken,
    uint256 _repayAmount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    // 2. send all collats under subaccount to strategy
    uint256 _collatAmountBefore = ERC20(_collatToken).balanceOf(address(this));
    uint256 _repayAmountBefore = ERC20(_repayToken).balanceOf(address(this));

    ERC20(_collatToken).safeTransfer(
      _liquidationStrat,
      moneyMarketDs.subAccountCollats[_subAccount].getAmount(_collatToken)
    );

    // 3. call executeLiquidation on strategy
    ILiquidationStrategy(_liquidationStrat).executeLiquidation(
      _collatToken,
      _repayToken,
      _getActualRepayAmount(_subAccount, _repayToken, _repayAmount, moneyMarketDs),
      address(this)
    );

    // 4. check repaid amount, take fees, and update states
    uint256 _amountRepaid = ERC20(_repayToken).balanceOf(address(this)) - _repayAmountBefore;
    uint256 _collatAmountAfter = ERC20(_collatToken).balanceOf(address(this));
    uint256 _collatSold = _collatAmountBefore - _collatAmountAfter;

    // TODO: transfer fee to treasury
    uint256 _collatFeeToTreasury = (_collatSold * LIQUIDATION_FEE_BPS) / 10000;
    // for case that _collatAmountAfter is not enough for fee
    // ex. _totalCollatAmount = 10, _collatSold = 9.99, _fee (1%) = 0.0999, _collatAmountAfter = 0.01
    // actual fee should be 0.01
    uint256 _actualCollatFeeToTreasury = _collatFeeToTreasury > _collatAmountAfter
      ? _collatAmountAfter
      : _collatFeeToTreasury;

    _reduceDebt(_subAccount, _repayToken, _amountRepaid, moneyMarketDs); // use _amountRepaid so that bad debt will be reflected directly on subaccount
    _reduceCollateral(_subAccount, _collatToken, _collatSold + _actualCollatFeeToTreasury, moneyMarketDs);

    emit LogLiquidate(
      msg.sender,
      _liquidationStrat,
      _repayToken,
      _collatToken,
      _amountRepaid,
      _collatSold,
      _collatFeeToTreasury
    );
  }

  function _ibLiquidationCall(
    address _liquidationStrat,
    address _subAccount,
    address _repayToken,
    address _collatToken, // ib token
    address _collatUnderlyingToken,
    uint256 _repayAmount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    // 2. calculate collat amount to send to liquidator based on _repayAmount
    uint256 _actualRepayAmount = _getActualRepayAmount(_subAccount, _repayToken, _repayAmount, moneyMarketDs);

    // prevent stack too deep
    uint256 _collatUnderlyingAmountOut;
    {
      (uint256 _repayTokenPrice, ) = LibMoneyMarket01.getPriceUSD(_repayToken, moneyMarketDs);
      uint256 _repayInUSD = (_actualRepayAmount *
        moneyMarketDs.tokenConfigs[_repayToken].to18ConversionFactor *
        _repayTokenPrice) / 1e18;
      _collatUnderlyingAmountOut = _getCollatUnderlyingAmountOut(
        _subAccount,
        _collatUnderlyingToken,
        _collatToken,
        _repayInUSD,
        LIQUIDATION_REWARD_BPS,
        moneyMarketDs
      );
    }

    // 3. update states
    uint256 _ibAmountOut = ILendFacet(address(this)).getIbShareFromUnderlyingAmount(
      _collatUnderlyingToken,
      _collatUnderlyingAmountOut
    );

    _reduceDebt(_subAccount, _repayToken, _actualRepayAmount, moneyMarketDs);
    _reduceCollateral(_subAccount, _collatToken, _ibAmountOut, moneyMarketDs);

    uint256 _repayAmountBefore = ERC20(_repayToken).balanceOf(address(this));

    // 4. withdraw underlying and transfer them to liquidator and call liquidate
    // note that liquidation bonus will be underlying token not ib
    LibMoneyMarket01.withdraw(_collatToken, _ibAmountOut, address(this), moneyMarketDs);
    ERC20(_collatUnderlyingToken).safeTransfer(_liquidationStrat, _collatUnderlyingAmountOut);
    // ILiquidationStrategy(_liquidationStrat).executeLiquidation(
    //   _collatUnderlyingToken,
    //   _repayToken,
    //   _actualRepayAmount,
    //   address(this),
    //   msg.sender
    // );

    // 5. check if we get expected amount of repayToken back from liquidator
    uint256 _amountRepaid = ERC20(_repayToken).balanceOf(address(this)) - _repayAmountBefore;
    if (_amountRepaid < _actualRepayAmount) {
      revert LiquidationFacet_RepayAmountMismatch();
    }

    emit LogLiquidateIb(
      msg.sender,
      _liquidationStrat,
      _repayToken,
      _collatToken,
      _amountRepaid,
      _ibAmountOut,
      _collatUnderlyingAmountOut
    );
  }

  /// @dev max(repayAmount, debtValue)
  function _getActualRepayAmount(
    address _subAccount,
    address _repayToken,
    uint256 _repayAmount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _actualRepayAmount) {
    uint256 _debtShare = moneyMarketDs.subAccountDebtShares[_subAccount].getAmount(_repayToken);
    // for ib debtValue is in ib shares not in underlying
    uint256 _debtValue = LibShareUtil.shareToValue(
      _debtShare,
      moneyMarketDs.debtValues[_repayToken],
      moneyMarketDs.debtShares[_repayToken]
    );

    _actualRepayAmount = _repayAmount > _debtValue ? _debtValue : _repayAmount;
  }

  function _getCollatAmountOut(
    address _subAccount,
    address _collatToken,
    uint256 _collatValueInUSD,
    uint256 _rewardBps,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _collatTokenAmountOut) {
    (uint256 _collatTokenPrice, ) = LibMoneyMarket01.getPriceUSD(_collatToken, moneyMarketDs);

    uint256 _rewardInUSD = (_collatValueInUSD * _rewardBps) / 10000;

    LibMoneyMarket01.TokenConfig memory _tokenConfig = moneyMarketDs.tokenConfigs[_collatToken];

    _collatTokenAmountOut =
      ((_collatValueInUSD + _rewardInUSD) * 1e18) /
      (_collatTokenPrice * _tokenConfig.to18ConversionFactor);

    uint256 _collatTokenTotalAmount = moneyMarketDs.subAccountCollats[_subAccount].getAmount(_collatToken);

    if (_collatTokenAmountOut > _collatTokenTotalAmount) {
      revert LiquidationFacet_InsufficientAmount();
    }
  }

  function _getCollatUnderlyingAmountOut(
    address _subAccount,
    address _underlyingToken,
    address _collatIbToken,
    uint256 _repayInUSD,
    uint256 _rewardBps,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal view returns (uint256 _underlyingAmountOut) {
    (uint256 _underlyingTokenPrice, ) = LibMoneyMarket01.getPriceUSD(_underlyingToken, moneyMarketDs);
    _underlyingAmountOut =
      ((_repayInUSD * (1e4 + _rewardBps)) * 1e14) /
      (_underlyingTokenPrice * moneyMarketDs.tokenConfigs[_underlyingToken].to18ConversionFactor);

    uint256 _totalIbCollatInUnderlyingAmount = ILendFacet(address(this)).getIbShareFromUnderlyingAmount(
      _underlyingToken,
      moneyMarketDs.subAccountCollats[_subAccount].getAmount(_collatIbToken)
    );

    if (_underlyingAmountOut > _totalIbCollatInUnderlyingAmount) {
      revert LiquidationFacet_InsufficientAmount();
    }
  }

  function _reduceDebt(
    address _subAccount,
    address _repayToken,
    uint256 _repayAmount,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    uint256 _debtShare = moneyMarketDs.subAccountDebtShares[_subAccount].getAmount(_repayToken);
    uint256 _repayShare = LibShareUtil.valueToShare(
      _repayAmount,
      moneyMarketDs.debtShares[_repayToken],
      moneyMarketDs.debtValues[_repayToken]
    );
    moneyMarketDs.subAccountDebtShares[_subAccount].updateOrRemove(_repayToken, _debtShare - _repayShare);
    moneyMarketDs.debtShares[_repayToken] -= _repayShare;
    moneyMarketDs.debtValues[_repayToken] -= _repayAmount;
  }

  function _reduceCollateral(
    address _subAccount,
    address _collatToken,
    uint256 _amountOut,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    uint256 _collatTokenAmount = moneyMarketDs.subAccountCollats[_subAccount].getAmount(_collatToken);
    moneyMarketDs.subAccountCollats[_subAccount].updateOrRemove(_collatToken, _collatTokenAmount - _amountOut);
    moneyMarketDs.collats[_collatToken] -= _amountOut;
  }
}
