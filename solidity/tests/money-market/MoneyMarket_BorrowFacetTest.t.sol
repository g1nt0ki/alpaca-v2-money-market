// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { MoneyMarket_BaseTest, MockERC20, console } from "./MoneyMarket_BaseTest.t.sol";

// interfaces
import { IBorrowFacet, LibDoublyLinkedList } from "../../contracts/money-market/facets/BorrowFacet.sol";
import { IAdminFacet } from "../../contracts/money-market/facets/AdminFacet.sol";

contract MoneyMarket_BorrowFacetTest is MoneyMarket_BaseTest {
  MockERC20 mockToken;

  function setUp() public override {
    super.setUp();

    mockToken = deployMockErc20("Mock token", "MOCK", 18);
    mockToken.mint(ALICE, 1000 ether);

    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 50 ether);
    lendFacet.deposit(address(usdc), 20 ether);
    lendFacet.deposit(address(isolateToken), 20 ether);
    vm.stopPrank();
  }

  function testCorrectness_WhenUserBorrowTokenFromMM_ShouldTransferTokenToUser()
    external
  {
    uint256 _borrowAmount = 10 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(
      BOB,
      subAccount0,
      address(weth),
      _borrowAmount * 2
    );

    uint256 _bobBalanceBefore = weth.balanceOf(BOB);
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    vm.stopPrank();

    uint256 _bobBalanceAfter = weth.balanceOf(BOB);

    assertEq(_bobBalanceAfter - _bobBalanceBefore, _borrowAmount);

    uint256 _debtAmount;
    (, _debtAmount) = borrowFacet.getDebt(BOB, subAccount0, address(weth));
    assertEq(_debtAmount, _borrowAmount);
    // sanity check on subaccount1
    (, _debtAmount) = borrowFacet.getDebt(BOB, subAccount1, address(weth));

    assertEq(_debtAmount, 0);
  }

  function testRevert_WhenUserBorrowNonAvailableToken_ShouldRevert() external {
    uint256 _borrowAmount = 10 ether;
    vm.startPrank(BOB);
    vm.expectRevert(
      abi.encodeWithSelector(
        IBorrowFacet.BorrowFacet_InvalidToken.selector,
        address(mockToken)
      )
    );
    borrowFacet.borrow(subAccount0, address(mockToken), _borrowAmount);
    vm.stopPrank();
  }

  function testCorrectness_WhenUserBorrowMultipleTokens_ListShouldUpdate()
    external
  {
    uint256 _aliceBorrowAmount = 10 ether;
    uint256 _aliceBorrowAmount2 = 20 ether;

    vm.startPrank(ALICE);

    collateralFacet.addCollateral(ALICE, subAccount0, address(weth), 100 ether);

    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount);
    vm.stopPrank();

    LibDoublyLinkedList.Node[] memory aliceDebtShares = borrowFacet
      .getDebtShares(ALICE, subAccount0);

    assertEq(aliceDebtShares.length, 1);
    assertEq(aliceDebtShares[0].amount, _aliceBorrowAmount);

    vm.startPrank(ALICE);

    // list will be add at the front of linkList
    borrowFacet.borrow(subAccount0, address(usdc), _aliceBorrowAmount2);
    vm.stopPrank();

    aliceDebtShares = borrowFacet.getDebtShares(ALICE, subAccount0);

    assertEq(aliceDebtShares.length, 2);
    assertEq(aliceDebtShares[0].amount, _aliceBorrowAmount2);
    assertEq(aliceDebtShares[1].amount, _aliceBorrowAmount);

    vm.startPrank(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount);
    vm.stopPrank();

    aliceDebtShares = borrowFacet.getDebtShares(ALICE, subAccount0);

    assertEq(aliceDebtShares.length, 2);
    assertEq(aliceDebtShares[0].amount, _aliceBorrowAmount2);
    assertEq(aliceDebtShares[1].amount, _aliceBorrowAmount * 2, "updated weth");
  }

  function testRevert_WhenUserBorrowMoreThanAvailable_ShouldRevert() external {
    uint256 _aliceBorrowAmount = 20 ether;

    vm.startPrank(ALICE);

    collateralFacet.addCollateral(ALICE, subAccount0, address(weth), 100 ether);

    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount);
    vm.stopPrank();

    LibDoublyLinkedList.Node[] memory aliceDebtShares = borrowFacet
      .getDebtShares(ALICE, subAccount0);

    assertEq(aliceDebtShares.length, 1);
    assertEq(aliceDebtShares[0].amount, _aliceBorrowAmount);

    vm.startPrank(ALICE);

    // list will be add at the front of linkList
    vm.expectRevert(
      abi.encodeWithSelector(
        IBorrowFacet.BorrowFacet_NotEnoughToken.selector,
        _aliceBorrowAmount * 2
      )
    );
    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount * 2);
    vm.stopPrank();
  }

  function testCorrectness_WhenMultipleUserBorrowTokens_MMShouldTransferCorrectIbTokenAmount()
    external
  {
    uint256 _bobDepositAmount = 10 ether;
    uint256 _aliceBorrowAmount = 10 ether;

    vm.startPrank(ALICE);
    collateralFacet.addCollateral(ALICE, subAccount0, address(weth), 100 ether);
    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount);
    vm.stopPrank();

    vm.startPrank(BOB);
    weth.approve(moneyMarketDiamond, type(uint256).max);
    lendFacet.deposit(address(weth), _bobDepositAmount);

    vm.stopPrank();

    assertEq(ibWeth.balanceOf(BOB), 10 ether);
  }

  function testRevert_WhenBorrowPowerLessThanBorrowingValue_ShouldRevert()
    external
  {
    uint256 _aliceCollatAmount = 5 ether;
    uint256 _aliceBorrowAmount = 5 ether;

    vm.startPrank(ALICE);

    collateralFacet.addCollateral(
      ALICE,
      subAccount0,
      address(weth),
      _aliceCollatAmount * 2
    );

    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount);
    vm.expectRevert();
    borrowFacet.borrow(subAccount0, address(weth), _aliceBorrowAmount);

    vm.stopPrank();
  }

  function testCorrectness_WhenUserHaveNotBorrow_ShouldAbleToBorrowIsolateAsset()
    external
  {
    uint256 _bobIsloateBorrowAmount = 5 ether;
    uint256 _bobCollateralAmount = 10 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(
      BOB,
      subAccount0,
      address(weth),
      _bobCollateralAmount
    );

    borrowFacet.borrow(
      subAccount0,
      address(isolateToken),
      _bobIsloateBorrowAmount
    );
    vm.stopPrank();
  }

  function testRevert_WhenUserAlreadyBorrowIsloateToken_ShouldRevertIfTryToBorrowDifferentToken()
    external
  {
    uint256 _bobIsloateBorrowAmount = 5 ether;
    uint256 _bobCollateralAmount = 20 ether;

    vm.startPrank(BOB);
    collateralFacet.addCollateral(
      BOB,
      subAccount0,
      address(weth),
      _bobCollateralAmount
    );

    // first borrow isolate token
    borrowFacet.borrow(
      subAccount0,
      address(isolateToken),
      _bobIsloateBorrowAmount
    );

    // borrow the isolate token again should passed
    borrowFacet.borrow(
      subAccount0,
      address(isolateToken),
      _bobIsloateBorrowAmount
    );

    // trying to borrow different asset
    vm.expectRevert(
      abi.encodeWithSelector(IBorrowFacet.BorrowFacet_InvalidAssetTier.selector)
    );
    borrowFacet.borrow(subAccount0, address(weth), _bobIsloateBorrowAmount);
    vm.stopPrank();
  }

  function testCorrectness_WhenUserBorrowToken_BorrowingPowerAndBorrowedValueShouldCalculateCorrectly()
    external
  {
    uint256 _aliceCollatAmount = 5 ether;

    vm.prank(ALICE);
    collateralFacet.addCollateral(
      ALICE,
      subAccount0,
      address(weth),
      _aliceCollatAmount
    );

    uint256 _borrowingPowerUSDValue = borrowFacet.getTotalBorrowingPower(
      ALICE,
      subAccount0
    );

    // add 5 weth, collateralFactor = 9000, weth price = 1
    // _borrowingPowerUSDValue = 5 * 1 * 9000/ 10000 = 4.5 ether USD
    assertEq(_borrowingPowerUSDValue, 4.5 ether);

    // borrowFactor = 1000, weth price = 1
    // maximumBorrowedUSDValue = _borrowingPowerUSDValue = 4.5 USD
    // maximumBorrowed weth amount = 4.5 * 10000/(10000 + 1000) ~ 4.09090909090909
    // _borrowedUSDValue = 4.09090909090909 * (10000 + 1000)/10000 = 4.499999999999999
    vm.prank(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), 4.09090909090909 ether);

    (uint256 _borrowedUSDValue, ) = borrowFacet.getTotalUsedBorrowedPower(
      ALICE,
      subAccount0
    );
    assertEq(_borrowedUSDValue, 4.499999999999999 ether);
  }

  function testCorrectness_WhenUserBorrowToken_BorrowingPowerAndBorrowedValueShouldCalculateCorrectlyWithIbTokenCollat()
    external
  {
    uint256 _aliceCollatAmount = 5 ether;
    uint256 _ibTokenCollatAmount = 5 ether;

    vm.startPrank(ALICE);
    weth.approve(moneyMarketDiamond, _aliceCollatAmount);
    ibWeth.approve(moneyMarketDiamond, _ibTokenCollatAmount);

    // add by actual token
    collateralFacet.addCollateral(
      ALICE,
      subAccount0,
      address(weth),
      _aliceCollatAmount
    );
    // add by ibToken
    collateralFacet.addCollateral(
      ALICE,
      subAccount0,
      address(ibWeth),
      _ibTokenCollatAmount
    );
    vm.stopPrank();

    uint256 _borrowingPowerUSDValue = borrowFacet.getTotalBorrowingPower(
      ALICE,
      subAccount0
    );

    // add 5 weth, collateralFactor = 9000, weth price = 1
    // _borrowingPowerUSDValue = 5 * 1 * 9000 / 10000 = 4.5 ether USD
    // totalSupply = 50
    // totalToken = 55 - 5 (balance - collat) = 50
    // ibCollatAmount = 5
    // borrowIbTokenAmountInToken = 5 * (50 / 50) (ibCollatAmount * (totalSupply / totalToken)) = 5
    // _borrowingPowerUSDValue of ibToken = 5 * 1 * 9000 / 10000 = 4.5 ether USD
    // then 4.5 + 4.5 = 9
    assertEq(_borrowingPowerUSDValue, 9 ether);

    // borrowFactor = 1000, weth price = 1
    // maximumBorrowedUSDValue = _borrowingPowerUSDValue = 9 USD
    // maximumBorrowed weth amount = 9 * 10000/(10000 + 1000) ~ 8.181818181818181818
    // _borrowedUSDValue = 8.181818181818181818 * (10000 + 1000) / 10000 = 8.999999999999999999
    vm.prank(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), 8.181818181818181818 ether);

    (uint256 _borrowedUSDValue, ) = borrowFacet.getTotalUsedBorrowedPower(
      ALICE,
      subAccount0
    );
    assertEq(_borrowedUSDValue, 8.999999999999999999 ether);
  }

  function testCorrectness_WhenUserBorrowToken_BorrowingPowerAndBorrowedValueShouldCalculateCorrectlyWithIbTokenCollat_ibTokenIsNot1to1WithToken()
    external
  {
    uint256 _aliceCollatAmount = 5 ether;
    uint256 _ibTokenCollatAmount = 5 ether;

    vm.startPrank(ALICE);
    weth.approve(moneyMarketDiamond, _aliceCollatAmount);
    ibWeth.approve(moneyMarketDiamond, _ibTokenCollatAmount);

    // add by actual token
    collateralFacet.addCollateral(
      ALICE,
      subAccount0,
      address(weth),
      _aliceCollatAmount
    );
    // add by ibToken
    collateralFacet.addCollateral(
      ALICE,
      subAccount0,
      address(ibWeth),
      _ibTokenCollatAmount
    );
    vm.stopPrank();

    vm.prank(ALICE);
    weth.transfer(moneyMarketDiamond, 50 ether);

    uint256 _borrowingPowerUSDValue = borrowFacet.getTotalBorrowingPower(
      ALICE,
      subAccount0
    );

    // add 5 weth, collateralFactor = 9000, weth price = 1
    // _borrowingPowerUSDValue = 5 * 1 * 9000 / 10000 = 4.5 ether USD
    // totalSupply = 50
    // totalToken = 105 - 5 (balance - collat) = 100
    // ibCollatAmount = 5
    // borrowIbTokenAmountInToken = 5 * (50 / 100) (ibCollatAmount * (totalSupply / totalToken)) = 2.5
    // _borrowingPowerUSDValue of ibToken = 2.5 * 1 * 9000 / 10000 = 2.25 ether USD
    // then 4.5 + 2.25 = 9
    assertEq(_borrowingPowerUSDValue, 6.75 ether);

    // borrowFactor = 1000, weth price = 1
    // maximumBorrowedUSDValue = _borrowingPowerUSDValue = 6.75 USD
    // maximumBorrowed weth amount = 6.75 * 10000/(10000 + 1000) ~ 6.136363636363636363
    // _borrowedUSDValue = 6.136363636363636363 * (10000 + 1000) / 10000 ~ 6.749999999999999999
    vm.prank(ALICE);
    borrowFacet.borrow(subAccount0, address(weth), 6.136363636363636363 ether);

    (uint256 _borrowedUSDValue, ) = borrowFacet.getTotalUsedBorrowedPower(
      ALICE,
      subAccount0
    );
    assertEq(_borrowedUSDValue, 6.749999999999999999 ether);
  }

  function testRevert_WhenUserBorrowMoreThanLimit_ShouldRevertBorrowFacetExceedBorrowLimit()
    external
  {
    // borrow cap is at 30 weth
    uint256 _borrowAmount = 20 ether;
    uint256 _bobCollateral = 100 ether;

    vm.startPrank(BOB);

    collateralFacet.addCollateral(
      BOB,
      subAccount0,
      address(weth),
      _bobCollateral
    );

    // first borrow should pass
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);

    // the second borrow will revert since it exceed the cap
    vm.expectRevert(
      abi.encodeWithSelector(
        IBorrowFacet.BorrowFacet_ExceedBorrowLimit.selector
      )
    );
    borrowFacet.borrow(subAccount0, address(weth), _borrowAmount);
    vm.stopPrank();
  }
}
