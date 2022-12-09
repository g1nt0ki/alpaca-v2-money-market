// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LYF_BaseTest, console } from "./LYF_BaseTest.t.sol";

// interfaces
import { ILYFLiquidationFacet } from "../../contracts/lyf/interfaces/ILYFLiquidationFacet.sol";

// mocks
import { MockERC20 } from "../mocks/MockERC20.sol";

// libraries
import { LibLYF01 } from "../../contracts/lyf/libraries/LibLYF01.sol";

contract LYF_LiquidationFacetTest is LYF_BaseTest {
  uint256 _subAccountId = 0;
  address _aliceSubAccount0 = LibLYF01.getSubAccount(ALICE, _subAccountId);

  uint256 constant REPURCHASE_REWARD_BPS = 100;
  uint256 constant REPURCHASE_FEE_BPS = 100;

  function setUp() public override {
    super.setUp();
  }

  function _calcCollatRepurchaserShouldReceive(uint256 debtToRepurchase, uint256 collatUSDPrice)
    internal
    pure
    returns (uint256 result)
  {
    uint256 collatToRepurchase = (debtToRepurchase * 1e18) / collatUSDPrice;
    result = (collatToRepurchase * (10000 + REPURCHASE_REWARD_BPS)) / 10000;
  }

  function testCorrectness_WhenPartialRepurchase_ShouldWork() external {
    /**
     * scenario:
     *
     * 1. @ 1 usdc/weth: alice add collateral 40 weth, open farm with 30 weth, 30 usdc
     *      - 30 weth collateral is used to open position -> 10 weth left as collateral
     *      - alice need to borrow 30 usdc
     *      - alice total borrowing power = (10 * 1 * 0.9) + (30 * 2 * 0.9) = 63 usd
     *
     * 2. lp price drops to 0.5 usdc/lp -> position become repurchaseable
     *      - alice total borrowing power = (10 * 1 * 0.9) + (30 * 0.5 * 0.9) = 22.5 usd
     *
     * 3. bob repurchase weth collateral with 5 usdc, bob will receive 5.05 weth
     *      - 5 / 1 = 5 weth will be repurchased by bob
     *      - 5 * 1% = 0.05 weth as repurchase reward for bob
     *
     * 4. alice position after repurchase
     *      - alice subaccount 0: weth collateral = 10 - 5.05 = 4.95 weth
     *      - alice subaccount 0: usdc debt = 30 - 5 = 25 usdc
     */
    address _collatToken = address(weth);
    address _debtToken = address(usdc);
    address _lpToken = address(wethUsdcLPToken);
    uint256 _amountToRepurchase = 5 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, _collatToken, 40 ether);
    farmFacet.addFarmPosition(subAccount0, _lpToken, 30 ether, 30 ether, 0);
    vm.stopPrank();

    uint256 _bobWethBalanceBefore = weth.balanceOf(BOB);
    uint256 _bobUsdcBalanceBefore = usdc.balanceOf(BOB);

    chainLinkOracle.add(_lpToken, address(usd), 0.5 ether, block.timestamp);

    vm.prank(BOB);
    liquidationFacet.repurchase(ALICE, subAccount0, _debtToken, _collatToken, _lpToken, _amountToRepurchase);

    // check bob balance
    uint256 _wethReceivedFromRepurchase = _calcCollatRepurchaserShouldReceive(_amountToRepurchase, 1 ether);
    assertEq(weth.balanceOf(BOB) - _bobWethBalanceBefore, _wethReceivedFromRepurchase);
    assertEq(_bobUsdcBalanceBefore - usdc.balanceOf(BOB), _amountToRepurchase);

    // check alice position
    assertEq(
      collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      10 ether - _wethReceivedFromRepurchase // TODO: account for repurchase fee
    );
    (, uint256 _aliceUsdcDebtValue) = farmFacet.getDebt(ALICE, subAccount0, address(usdc), _lpToken);
    assertEq(_aliceUsdcDebtValue, 25 ether);
  }

  function testCorrectness_WhenRepurchaseMoreThanDebt_ShouldRepurchaseAllDebtOnThatToken() external {
    /**
     * scenario:
     *
     * 1. @ 10 usdc/btc, 1 usdc/weth: alice add collateral 4 btc, open farm with 30 weth, 30 usdc
     *      - alice need to borrow 30 usdc, 30 weth -> borrowed value = 60 usd
     *
     * 2. lp price drops to 0.5 usdc/lp -> position become repurchaseable
     *      - alice total borrowing power = (10 * 4 * 0.9) + (30 * 0.5 * 0.9) = 49.5 usd
     *
     * 3. bob repurchase btc collateral with 40 usdc -> capped at 30 usdc, bob will receive 3.03 btc
     *      - 30 / 10 = 3 btc will be repurchased by bob
     *      - 3 * 1% = 0.03 btc as repurchase reward for bob
     *
     * 4. alice position after repurchase
     *      - alice subaccount 0: btc collateral = 4 - 3.03 = 0.97 btc
     *      - alice subaccount 0: usdc debt = 30 - 30 = 0 usdc
     *      - alice subaccount 0: weth debt = 30 weth unchanged
     */
    address _collatToken = address(btc);
    address _debtToken = address(usdc);
    address _lpToken = address(wethUsdcLPToken);
    uint256 _amountToRepurchase = 40 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, _collatToken, 4 ether);
    farmFacet.addFarmPosition(subAccount0, _lpToken, 30 ether, 30 ether, 0);
    vm.stopPrank();

    uint256 _bobBtcBalanceBefore = btc.balanceOf(BOB);
    uint256 _bobUsdcBalanceBefore = usdc.balanceOf(BOB);

    chainLinkOracle.add(_lpToken, address(usd), 0.5 ether, block.timestamp);

    vm.prank(BOB);
    liquidationFacet.repurchase(ALICE, subAccount0, _debtToken, _collatToken, _lpToken, _amountToRepurchase);

    // check bob balance
    uint256 _actualRepurchase = 30 ether;
    uint256 _btcReceivedFromRepurchase = _calcCollatRepurchaserShouldReceive(_actualRepurchase, 10 ether);
    assertEq(btc.balanceOf(BOB) - _bobBtcBalanceBefore, _btcReceivedFromRepurchase);
    assertEq(_bobUsdcBalanceBefore - usdc.balanceOf(BOB), _actualRepurchase);

    // check alice position
    assertEq(
      collateralFacet.subAccountCollatAmount(_aliceSubAccount0, _collatToken),
      4 ether - _btcReceivedFromRepurchase // TODO: account for repurchase fee
    );
    (, uint256 _aliceUsdcDebtValue) = farmFacet.getDebt(ALICE, subAccount0, address(usdc), _lpToken);
    assertEq(_aliceUsdcDebtValue, 0);
    (, uint256 _aliceWethDebtValue) = farmFacet.getDebt(ALICE, subAccount0, address(weth), _lpToken);
    assertEq(_aliceWethDebtValue, 30 ether);
  }

  function testRevert_WhenRepurchaseHealthySubAccount() external {
    address _collatToken = address(weth);
    address _debtToken = address(usdc);
    address _lpToken = address(wethUsdcLPToken);
    uint256 _amountToRepurchase = 5 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, _collatToken, 40 ether);
    farmFacet.addFarmPosition(subAccount0, _lpToken, 30 ether, 30 ether, 0);
    vm.stopPrank();

    vm.prank(BOB);
    vm.expectRevert(abi.encodeWithSelector(ILYFLiquidationFacet.LYFLiquidationFacet_Healthy.selector));
    liquidationFacet.repurchase(ALICE, subAccount0, _debtToken, _collatToken, _lpToken, _amountToRepurchase);
  }

  function testRevert_WhenRepurchaseMoreThanHalfOfDebt_WhileThereIs2DebtPosition() external {
    address _collatToken = address(btc);
    address _debtToken = address(usdc);
    address _lpToken = address(wethUsdcLPToken);
    uint256 _amountToRepurchase = 40 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, _collatToken, 4 ether);
    // open farm with 29 weth, 31 usdc borrowed
    farmFacet.addFarmPosition(subAccount0, _lpToken, 29 ether, 31 ether, 0);
    vm.stopPrank();

    chainLinkOracle.add(_lpToken, address(usd), 0.5 ether, block.timestamp);

    // bob try to liquidate 40 usdc, get capped at 31 usdc, should fail because it is more than half of total debt
    vm.prank(BOB);
    vm.expectRevert(abi.encodeWithSelector(ILYFLiquidationFacet.LYFLiquidationFacet_RepayDebtValueTooHigh.selector));
    liquidationFacet.repurchase(ALICE, subAccount0, _debtToken, _collatToken, _lpToken, _amountToRepurchase);
  }

  function testRevert_WhenNotEnoughCollatToPayForDebtAmount() external {
    address _collatToken = address(btc);
    address _debtToken = address(usdc);
    address _lpToken = address(wethUsdcLPToken);
    uint256 _amountToRepurchase = 30 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, _collatToken, 4 ether);
    // open farm with 29 weth, 31 usdc borrowed
    farmFacet.addFarmPosition(subAccount0, _lpToken, 30 ether, 30 ether, 0);
    vm.stopPrank();

    chainLinkOracle.add(_lpToken, address(usd), 0.5 ether, block.timestamp);
    chainLinkOracle.add(address(btc), address(usd), 1 ether, block.timestamp);

    // bob try to liquidate 30 usdc, should fail because btc collat value is less than 30 usd
    vm.prank(BOB);
    vm.expectRevert(abi.encodeWithSelector(ILYFLiquidationFacet.LYFLiquidationFacet_InsufficientAmount.selector));
    liquidationFacet.repurchase(ALICE, subAccount0, _debtToken, _collatToken, _lpToken, _amountToRepurchase);
  }
}
