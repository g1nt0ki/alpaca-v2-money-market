// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { LYF_BaseTest, MockERC20, console } from "./LYF_BaseTest.t.sol";

// interfaces
import { ILYFFarmFacet } from "../../contracts/lyf/facets/LYFFarmFacet.sol";
import { ILYFAdminFacet } from "../../contracts/lyf/interfaces/ILYFAdminFacet.sol";
import { IMoneyMarket } from "../../contracts/lyf/interfaces/IMoneyMarket.sol";

// mock
import { MockInterestModel } from "../mocks/MockInterestModel.sol";

// libraries
import { LibDoublyLinkedList } from "../../contracts/lyf/libraries/LibDoublyLinkedList.sol";
import { LibUIntDoublyLinkedList } from "../../contracts/lyf/libraries/LibUIntDoublyLinkedList.sol";
import { LibLYF01 } from "../../contracts/lyf/libraries/LibLYF01.sol";

contract LYF_Farm_ReducePositionTest is LYF_BaseTest {
  MockERC20 mockToken;

  function setUp() public override {
    super.setUp();

    mockToken = deployMockErc20("Mock token", "MOCK", 18);
    mockToken.mint(ALICE, 1000 ether);

    // mint and approve for setting reward in mockMasterChef
    cake.mint(address(this), 100000 ether);
    cake.approve(address(masterChef), type(uint256).max);
  }

  function testCorrectness_WhenUserReducePosition_LefoverTokenShouldReturnToUser() external {
    // remove interest for convienice of test
    adminFacet.setDebtPoolInterestModel(1, address(new MockInterestModel(0)));
    adminFacet.setDebtPoolInterestModel(2, address(new MockInterestModel(0)));

    uint256 _wethToAddLP = 40 ether;
    uint256 _usdcToAddLP = 40 ether;
    uint256 _wethCollatAmount = 20 ether;
    uint256 _usdcCollatAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _wethCollatAmount);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _usdcCollatAmount);

    farmFacet.addFarmPosition(subAccount0, address(wethUsdcLPToken), _wethToAddLP, _usdcToAddLP, 0);

    vm.stopPrank();

    masterChef.setReward(wethUsdcPoolId, lyfDiamond, 10 ether);

    assertEq(masterChef.pendingReward(wethUsdcPoolId, lyfDiamond), 10 ether);
    // asset collat of subaccount
    uint256 _subAccountWethCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(weth));
    uint256 _subAccountUsdcCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(usdc));
    uint256 _subAccountLpTokenCollat = viewFacet.getSubAccountTokenCollatAmount(
      BOB,
      subAccount0,
      address(wethUsdcLPToken)
    );

    assertEq(_subAccountWethCollat, 0 ether);
    assertEq(_subAccountUsdcCollat, 0 ether);

    // assume that every coin is 1 dollar and lp = 2 dollar

    assertEq(wethUsdcLPToken.balanceOf(lyfDiamond), 0 ether);
    assertEq(wethUsdcLPToken.balanceOf(address(masterChef)), 40 ether);
    assertEq(_subAccountLpTokenCollat, 40 ether);

    // mock remove liquidity will return token0: 2.5 ether and token1: 2.5 ether
    mockRouter.setRemoveLiquidityAmountsOut(2.5 ether, 2.5 ether);

    // should at lest left 18 usd as a debt
    adminFacet.setMinDebtSize(18 ether);

    vm.startPrank(BOB);
    // remove 5 lp,
    // repay 2 eth, 2 usdc
    farmFacet.reducePosition(subAccount0, address(wethUsdcLPToken), 5 ether, 0.5 ether, 0.5 ether);
    vm.stopPrank();

    assertEq(masterChef.pendingReward(wethUsdcPoolId, lyfDiamond), 0 ether);

    _subAccountWethCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(weth));
    _subAccountUsdcCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(usdc));
    _subAccountLpTokenCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(wethUsdcLPToken));

    // assert subaccount's collat
    assertEq(_subAccountWethCollat, 0 ether);
    assertEq(_subAccountUsdcCollat, 0 ether);

    assertEq(_subAccountLpTokenCollat, 35 ether); // starting at 40, remove 5, remain 35

    // assert subaccount's debt
    // check debt
    (, uint256 _subAccountWethDebtValue) = viewFacet.getSubAccountDebt(
      BOB,
      subAccount0,
      address(weth),
      address(wethUsdcLPToken)
    );
    (, uint256 _subAccountUsdcDebtValue) = viewFacet.getSubAccountDebt(
      BOB,
      subAccount0,
      address(usdc),
      address(wethUsdcLPToken)
    );

    // start at 20, repay 2, remain 18
    assertEq(_subAccountWethDebtValue, 18 ether);
    assertEq(_subAccountUsdcDebtValue, 18 ether);
  }

  function testCorrectness_WhenUserReducePosition_LefoverTokenShouldReturnToUser2() external {
    // remove interest for convienice of test
    adminFacet.setDebtPoolInterestModel(1, address(new MockInterestModel(0)));
    adminFacet.setDebtPoolInterestModel(2, address(new MockInterestModel(0)));

    uint256 _wethToAddLP = 40 ether;
    uint256 _usdcToAddLP = 40 ether;
    uint256 _wethCollatAmount = 20 ether;
    uint256 _usdcCollatAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _wethCollatAmount);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _usdcCollatAmount);

    farmFacet.addFarmPosition(subAccount0, address(wethUsdcLPToken), _wethToAddLP, _usdcToAddLP, 0);

    vm.stopPrank();

    masterChef.setReward(wethUsdcPoolId, lyfDiamond, 10 ether);

    assertEq(masterChef.pendingReward(wethUsdcPoolId, lyfDiamond), 10 ether);
    // asset collat of subaccount
    uint256 _subAccountWethCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(weth));
    uint256 _subAccountUsdcCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(usdc));
    uint256 _subAccountLpTokenCollat = viewFacet.getSubAccountTokenCollatAmount(
      BOB,
      subAccount0,
      address(wethUsdcLPToken)
    );

    assertEq(_subAccountWethCollat, 0 ether);
    assertEq(_subAccountUsdcCollat, 0 ether);

    // assume that every coin is 1 dollar and lp = 2 dollar

    assertEq(wethUsdcLPToken.balanceOf(lyfDiamond), 0 ether);
    assertEq(wethUsdcLPToken.balanceOf(address(masterChef)), 40 ether);
    assertEq(_subAccountLpTokenCollat, 40 ether);

    // mock remove liquidity will return token0: 30 ether and token1: 30 ether
    mockRouter.setRemoveLiquidityAmountsOut(30 ether, 30 ether);

    // should at lest left 10 usd as a debt
    adminFacet.setMinDebtSize(10 ether);

    uint256 wethBefore = weth.balanceOf(BOB);
    uint256 usdcBefore = usdc.balanceOf(BOB);

    vm.startPrank(BOB);
    // remove 5 lp,
    // repay 25 eth, 25 usdc
    farmFacet.reducePosition(subAccount0, address(wethUsdcLPToken), 5 ether, 5 ether, 5 ether);
    vm.stopPrank();

    assertEq(masterChef.pendingReward(wethUsdcPoolId, lyfDiamond), 0 ether);

    _subAccountWethCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(weth));
    _subAccountUsdcCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(usdc));
    _subAccountLpTokenCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(wethUsdcLPToken));

    // assert subaccount's collat
    assertEq(_subAccountWethCollat, 0 ether);
    assertEq(_subAccountUsdcCollat, 0 ether);

    assertEq(_subAccountLpTokenCollat, 35 ether); // starting at 40, remove 5, remain 35

    // assert subaccount's debt
    // check debt
    (, uint256 _subAccountWethDebtValue) = viewFacet.getSubAccountDebt(
      BOB,
      subAccount0,
      address(weth),
      address(wethUsdcLPToken)
    );
    (, uint256 _subAccountUsdcDebtValue) = viewFacet.getSubAccountDebt(
      BOB,
      subAccount0,
      address(usdc),
      address(wethUsdcLPToken)
    );

    // start at 20, repay 25, remain 0, transfer back 5
    assertEq(_subAccountWethDebtValue, 0 ether);
    assertEq(_subAccountUsdcDebtValue, 0 ether);

    assertEq(weth.balanceOf(BOB) - wethBefore, 10 ether, "BOB get WETH back wrong");
    assertEq(usdc.balanceOf(BOB) - usdcBefore, 10 ether, "BOB get USDC back wrong");
  }

  function testRevert_WhenUserReducePosition_RemainingDebtIsLessThanMinDebtSizeShouldRevert() external {
    // remove interest for convienice of test
    uint256 _wethToAddLP = 40 ether;
    uint256 _usdcToAddLP = 40 ether;
    uint256 _wethCollatAmount = 20 ether;
    uint256 _usdcCollatAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _wethCollatAmount);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _usdcCollatAmount);

    farmFacet.addFarmPosition(subAccount0, address(wethUsdcLPToken), _wethToAddLP, _usdcToAddLP, 0);

    vm.stopPrank();

    // asset collat of subaccount
    uint256 _subAccountWethCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(weth));
    uint256 _subAccountUsdcCollat = viewFacet.getSubAccountTokenCollatAmount(BOB, subAccount0, address(usdc));
    uint256 _subAccountLpTokenCollat = viewFacet.getSubAccountTokenCollatAmount(
      BOB,
      subAccount0,
      address(wethUsdcLPToken)
    );

    assertEq(_subAccountWethCollat, 0 ether);
    assertEq(_subAccountUsdcCollat, 0 ether);

    // assume that every coin is 1 dollar and lp = 2 dollar

    assertEq(wethUsdcLPToken.balanceOf(lyfDiamond), 0 ether);
    assertEq(wethUsdcLPToken.balanceOf(address(masterChef)), 40 ether);
    assertEq(_subAccountLpTokenCollat, 40 ether);

    // mock remove liquidity will return token0: 15 ether and token1: 15 ether
    mockRouter.setRemoveLiquidityAmountsOut(15 ether, 15 ether);
    adminFacet.setMinDebtSize(10 ether);
    vm.startPrank(BOB);

    // remove 15 lp,
    // repay 15 eth, 15 usdc
    vm.expectRevert(abi.encodeWithSelector(LibLYF01.LibLYF01_BorrowLessThanMinDebtSize.selector));
    farmFacet.reducePosition(subAccount0, address(wethUsdcLPToken), 15 ether, 0 ether, 0 ether);
    vm.stopPrank();
  }

  function testRevert_WhenUserReducePosition_IfSlippedShouldRevert() external {
    // remove interest for convienice of test
    adminFacet.setDebtPoolInterestModel(1, address(new MockInterestModel(0)));
    adminFacet.setDebtPoolInterestModel(2, address(new MockInterestModel(0)));
    uint256 _wethToAddLP = 40 ether;
    uint256 _usdcToAddLP = 40 ether;
    uint256 _wethCollatAmount = 20 ether;
    uint256 _usdcCollatAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _wethCollatAmount);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _usdcCollatAmount);

    farmFacet.addFarmPosition(subAccount0, address(wethUsdcLPToken), _wethToAddLP, _usdcToAddLP, 0);

    vm.stopPrank();

    masterChef.setReward(wethUsdcPoolId, lyfDiamond, 10 ether);

    // assume that every coin is 1 dollar and lp = 2 dollar
    // mock remove liquidity will return token0: 2.5 ether and token1: 2.5 ether
    mockRouter.setRemoveLiquidityAmountsOut(2.5 ether, 2.5 ether);

    vm.startPrank(BOB);
    wethUsdcLPToken.approve(address(mockRouter), 5 ether);
    // remove 5 lp,
    // repay 2 eth, 2 usdc
    vm.expectRevert(abi.encodeWithSelector(ILYFFarmFacet.LYFFarmFacet_TooLittleReceived.selector));
    farmFacet.reducePosition(subAccount0, address(wethUsdcLPToken), 5 ether, 3 ether, 3 ether);
    vm.stopPrank();
  }

  function testRevert_WhenUserReducePosition_IfResultedInUnhealthyStateShouldRevert() external {
    // remove interest for convienice of test
    adminFacet.setDebtPoolInterestModel(1, address(new MockInterestModel(0)));
    adminFacet.setDebtPoolInterestModel(2, address(new MockInterestModel(0)));
    uint256 _wethToAddLP = 40 ether;
    uint256 _usdcToAddLP = 40 ether;
    uint256 _wethCollatAmount = 20 ether;
    uint256 _usdcCollatAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(BOB, subAccount0, address(weth), _wethCollatAmount);
    collateralFacet.addCollateral(BOB, subAccount0, address(usdc), _usdcCollatAmount);

    farmFacet.addFarmPosition(subAccount0, address(wethUsdcLPToken), _wethToAddLP, _usdcToAddLP, 0);

    vm.stopPrank();

    // assume that every coin is 1 dollar and lp = 2 dollar
    // mock remove liquidity will return token0: 40 ether and token1: 40 ether
    mockRouter.setRemoveLiquidityAmountsOut(40 ether, 40 ether);

    vm.startPrank(BOB);
    wethUsdcLPToken.approve(address(mockRouter), 40 ether);
    // remove 40 lp,
    // repay 0 eth, 0 usdc
    vm.expectRevert(abi.encodeWithSelector(ILYFFarmFacet.LYFFarmFacet_BorrowingPowerTooLow.selector));
    farmFacet.reducePosition(subAccount0, address(wethUsdcLPToken), 40 ether, 40 ether, 40 ether);
    vm.stopPrank();
  }

  function testRevert_WhenUserAddInvalidLYFCollateral_ShouldRevert() external {
    vm.startPrank(ALICE);
    vm.expectRevert(abi.encodeWithSelector(ILYFFarmFacet.LYFFarmFacet_InvalidAssetTier.selector));
    farmFacet.reducePosition(subAccount0, address(weth), 5 ether, 0, 0);
    vm.stopPrank();
  }
}
