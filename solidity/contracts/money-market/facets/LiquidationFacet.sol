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

contract LiquidationFacet is ILiquidationFacet {
  using LibDoublyLinkedList for LibDoublyLinkedList.List;
  using SafeERC20 for ERC20;

  struct InternalLiquidationCallParams {
    address liquidationStrat;
    address subAccount;
    address repayToken;
    address collatToken;
    uint256 repayAmount;
  }

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

    InternalLiquidationCallParams memory _params = InternalLiquidationCallParams({
      liquidationStrat: _liquidationStrat,
      subAccount: _subAccount,
      repayToken: _repayToken,
      collatToken: _collatToken,
      repayAmount: _repayAmount
    });

    address _collatUnderlyingToken = moneyMarketDs.ibTokenToTokens[_collatToken];
    // handle liqudiate ib as collat
    if (_collatUnderlyingToken != address(0)) {
      _ibLiquidationCall(_params, _collatUnderlyingToken, moneyMarketDs);
    } else {
      _liquidationCall(_params, moneyMarketDs);
    }
  }

  function _liquidationCall(
    InternalLiquidationCallParams memory params,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    // 2. send all collats under subaccount to strategy
    uint256 _collatAmountBefore = ERC20(params.collatToken).balanceOf(address(this));
    uint256 _repayAmountBefore = ERC20(params.repayToken).balanceOf(address(this));

    ERC20(params.collatToken).safeTransfer(
      params.liquidationStrat,
      moneyMarketDs.subAccountCollats[params.subAccount].getAmount(params.collatToken)
    );

    // 3. call executeLiquidation on strategy
    ILiquidationStrategy(params.liquidationStrat).executeLiquidation(
      params.collatToken,
      params.repayToken,
      _getActualRepayAmount(params.subAccount, params.repayToken, params.repayAmount, moneyMarketDs),
      address(this)
    );

    // 4. check repaid amount, take fees, and update states
    uint256 _amountRepaid = ERC20(params.repayToken).balanceOf(address(this)) - _repayAmountBefore;
    uint256 _collatSold = _collatAmountBefore - ERC20(params.collatToken).balanceOf(address(this));

    // TODO: transfer fee to treasury
    uint256 _actualCollatFeeToTreasury = _getActualCollatFeeToTreasury(_collatAmountBefore, _collatSold);

    _reduceDebt(params.subAccount, params.repayToken, _amountRepaid, moneyMarketDs); // use _amountRepaid so that bad debt will be reflected directly on subaccount
    _reduceCollateral(params.subAccount, params.collatToken, _collatSold + _actualCollatFeeToTreasury, moneyMarketDs);

    emit LogLiquidate(
      msg.sender,
      params.liquidationStrat,
      params.repayToken,
      params.collatToken,
      _amountRepaid,
      _collatSold,
      _actualCollatFeeToTreasury
    );
  }

  function _ibLiquidationCall(
    InternalLiquidationCallParams memory params,
    address _collatUnderlyingToken,
    LibMoneyMarket01.MoneyMarketDiamondStorage storage moneyMarketDs
  ) internal {
    // 2. convert collat amount under subaccount to underlying amount and send underlying to strategy
    uint256 _subAccountCollatAmountBefore = moneyMarketDs.subAccountCollats[params.subAccount].getAmount(
      params.collatToken
    );
    uint256 _underlyingAmountBefore = ERC20(_collatUnderlyingToken).balanceOf(address(this));
    uint256 _repayAmountBefore = ERC20(params.repayToken).balanceOf(address(this));

    // if mm has no actual token left, withdraw will fail anyway
    ERC20(_collatUnderlyingToken).safeTransfer(
      params.liquidationStrat,
      _shareToValue(params.collatToken, _subAccountCollatAmountBefore, _underlyingAmountBefore)
    );

    // 3. call executeLiquidation on strategy to liquidate underlying token
    ILiquidationStrategy(params.liquidationStrat).executeLiquidation(
      _collatUnderlyingToken,
      params.repayToken,
      _getActualRepayAmount(params.subAccount, params.repayToken, params.repayAmount, moneyMarketDs),
      address(this)
    );

    // 4. check repaid amount, take fees, and update states
    uint256 _amountRepaid = ERC20(params.repayToken).balanceOf(address(this)) - _repayAmountBefore;
    uint256 _underlyingSold = _underlyingAmountBefore - ERC20(_collatUnderlyingToken).balanceOf(address(this));
    uint256 _collatSold = _valueToShare(params.collatToken, _underlyingSold, _underlyingAmountBefore);

    // TODO: transfer fee to treasury
    uint256 _actualCollatFeeToTreasury = _getActualCollatFeeToTreasury(_subAccountCollatAmountBefore, _collatSold);

    LibMoneyMarket01.withdraw(
      params.collatToken,
      _collatSold + _actualCollatFeeToTreasury,
      address(this),
      moneyMarketDs
    );
    _reduceDebt(params.subAccount, params.repayToken, _amountRepaid, moneyMarketDs); // use _amountRepaid so that bad debt will be reflected directly on subaccount
    _reduceCollateral(params.subAccount, params.collatToken, _collatSold + _actualCollatFeeToTreasury, moneyMarketDs);

    emit LogLiquidateIb(
      msg.sender,
      params.liquidationStrat,
      params.repayToken,
      params.collatToken,
      _amountRepaid,
      _collatSold,
      _underlyingSold,
      _actualCollatFeeToTreasury
    );
  }

  function _getActualCollatFeeToTreasury(uint256 _collatBefore, uint256 _collatSold)
    internal
    pure
    returns (uint256 _actualCollatFeeToTreasury)
  {
    uint256 _collatAmountAfter = _collatBefore - _collatSold;
    uint256 _collatFeeToTreasury = (_collatSold * LIQUIDATION_FEE_BPS) / 10000;
    // for case that _collatAmountAfter is not enough for fee
    // ex. _totalCollatAmount = 10, _collatSold = 9.99, _fee (1%) = 0.0999, _collatAmountAfter = 0.01
    // actual fee should be 0.01
    _actualCollatFeeToTreasury = _collatFeeToTreasury > _collatAmountAfter ? _collatAmountAfter : _collatFeeToTreasury;
  }

  function _valueToShare(
    address _ibToken,
    uint256 _value,
    uint256 _totalToken
  ) internal view returns (uint256 _shareValue) {
    uint256 _totalSupply = ERC20(_ibToken).totalSupply();

    _shareValue = LibShareUtil.valueToShare(_value, _totalSupply, _totalToken);
  }

  function _shareToValue(
    address _ibToken,
    uint256 _shareAmount,
    uint256 _totalToken
  ) internal view returns (uint256 _underlyingAmount) {
    uint256 _totalSupply = ERC20(_ibToken).totalSupply();

    _underlyingAmount = LibShareUtil.shareToValue(_shareAmount, _totalToken, _totalSupply);
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
