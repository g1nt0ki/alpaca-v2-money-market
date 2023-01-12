// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { MoneyMarket_BaseTest, MockERC20, console } from "./MoneyMarket_BaseTest.t.sol";

// libs
import { LibMoneyMarket01 } from "../../contracts/money-market/libraries/LibMoneyMarket01.sol";

// interfaces
import { ILiquidationFacet } from "../../contracts/money-market/facets/LiquidationFacet.sol";
import { TripleSlopeModel6, IInterestRateModel } from "../../contracts/money-market/interest-models/TripleSlopeModel6.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

// contract
import { PancakeswapV2IbTokenLiquidationStrategy } from "../../contracts/money-market/PancakeswapV2IbTokenLiquidationStrategy.sol";

// mocks
import { MockLiquidationStrategy } from "../mocks/MockLiquidationStrategy.sol";
import { MockBadLiquidationStrategy } from "../mocks/MockBadLiquidationStrategy.sol";
import { MockInterestModel } from "../mocks/MockInterestModel.sol";
import { MockLPToken } from "../mocks/MockLPToken.sol";
import { MockRouter } from "../mocks/MockRouter.sol";

struct CacheState {
  // general
  uint256 mmUnderlyingBalance;
  uint256 ibTokenTotalSupply;
  uint256 treasuryDebtTokenBalance;
  // debt
  uint256 globalDebtValue;
  uint256 debtValue;
  uint256 debtShare;
  uint256 subAccountDebtShare;
  // collat
  uint256 ibTokenCollat;
  uint256 subAccountIbTokenCollat;
}

contract MoneyMarket_Liquidation_IbLiquidationTest is MoneyMarket_BaseTest {
  MockLPToken internal wethUsdcLPToken;
  MockRouter internal router;
  PancakeswapV2IbTokenLiquidationStrategy _ibTokenLiquidationStrat;

  uint256 _aliceSubAccountId = 0;
  address _aliceSubAccount0 = LibMoneyMarket01.getSubAccount(ALICE, _aliceSubAccountId);
  address treasury;

  function setUp() public override {
    super.setUp();

    treasury = address(this);

    TripleSlopeModel6 tripleSlope6 = new TripleSlopeModel6();
    adminFacet.setInterestModel(address(weth), address(tripleSlope6));
    adminFacet.setInterestModel(address(btc), address(tripleSlope6));
    adminFacet.setInterestModel(address(usdc), address(tripleSlope6));

    // setup liquidationStrategy
    wethUsdcLPToken = new MockLPToken("MOCK LP", "MOCK LP", 18, address(weth), address(usdc));
    router = new MockRouter(address(wethUsdcLPToken));
    usdc.mint(address(router), 100 ether); // prepare for swap

    _ibTokenLiquidationStrat = new PancakeswapV2IbTokenLiquidationStrategy(
      address(router),
      address(moneyMarketDiamond)
    );

    address[] memory _ibTokenLiquidationStrats = new address[](2);
    _ibTokenLiquidationStrats[0] = address(_ibTokenLiquidationStrat);

    adminFacet.setLiquidationStratsOk(_ibTokenLiquidationStrats, true);

    address[] memory _liquidationCallers = new address[](2);
    _liquidationCallers[0] = BOB;
    _liquidationCallers[1] = address(this);
    adminFacet.setLiquidatorsOk(_liquidationCallers, true);

    address[] memory _liquidationExecutors = new address[](1);
    _liquidationExecutors[0] = address(moneyMarketDiamond);
    _ibTokenLiquidationStrat.setCallersOk(_liquidationExecutors, true);

    address[] memory _paths = new address[](2);
    _paths[0] = address(weth);
    _paths[1] = address(usdc);

    PancakeswapV2IbTokenLiquidationStrategy.SetPathParams[]
      memory _setPathsInputs = new PancakeswapV2IbTokenLiquidationStrategy.SetPathParams[](1);
    _setPathsInputs[0] = PancakeswapV2IbTokenLiquidationStrategy.SetPathParams({ path: _paths });

    _ibTokenLiquidationStrat.setPaths(_setPathsInputs);

    vm.startPrank(DEPLOYER);
    mockOracle.setTokenPrice(address(btc), 10 ether);
    vm.stopPrank();

    // bob deposit 100 usdc and 10 btc
    vm.startPrank(BOB);
    lendFacet.deposit(address(usdc), 100 ether);
    lendFacet.deposit(address(btc), 10 ether);
    vm.stopPrank();

    // alice add ibWETh collat for 40 ether
    vm.startPrank(ALICE);
    lendFacet.deposit(address(weth), 40 ether);
    collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
    // alice added collat 40 ether
    // given collateralFactor = 9000, weth price = 1
    // then alice got power = 40 * 1 * 9000 / 10000 = 36 ether USD
    vm.stopPrank();
  }

  function testCorrectness_WhenPartialLiquidateIbCollateral_ShouldRedeemUnderlyingToPayDebtCorrectly() external {
    // alice borrow 30 USDC
    vm.prank(ALICE);
    borrowFacet.borrow(0, address(usdc), 30 ether);
    // | ALICE  --------------------------|
    // | TOKEN  | DEBT VALUE | DEBT SHARE |
    // | usdc   | 30 ether   | 30 ether   |
    // | global | 30 ether   | 30 ether   |

    // criteria
    address _ibCollatToken = address(ibWeth);
    address _underlyingToken = address(weth);
    address _debtToken = address(usdc);
    uint256 _repayAmountInput = 15 ether; // reflect with amountIn[0] in strat
    uint256 _liquidationFee = 0.15 ether; // 1% of _repayAmountInput

    CacheState memory _stateBefore = _cacheState(_aliceSubAccount0, _ibCollatToken, _underlyingToken, _debtToken);

    // Time past for 1 day
    vm.warp(block.timestamp + 1 days);
    // | DEBT TOKEN | Borrowed Ratio | interest rate per day |
    // | usdc       | 30%            | 0.00016921837224      |

    // PendindInterest = BoorowedAmount * InterestRate * Timepast (1 day)
    // PendindInterest = 30 * 0.00016921837224 = 0.0050765511672
    uint256 _pendingInterest = viewFacet.getGlobalPendingInterest(_debtToken);
    assertEq(_pendingInterest, 0.0050765511672 ether, "pending interest for _debtToken");

    // increase shareValue of ibWeth by 2.5%
    // would need 18.2926829268... ibWeth to redeem 18.75 weth to repay debt
    // vm.prank(BOB);
    // lendFacet.deposit(address(weth), 1 ether);
    // vm.prank(moneyMarketDiamond);
    // ibWeth.onWithdraw(BOB, BOB, 0, 1 ether);

    // Prepare before liquidation
    // Dump WETH price from 1 USD to 0.8 USD, make position unhealthy
    mockOracle.setTokenPrice(address(weth), 8e17);
    mockOracle.setTokenPrice(address(usdc), 1 ether);

    // Liquitation Facet
    // |-------------------------------------------------------------------------- |
    // | #  | Detail                   | Amount                 | Note             |
    // | -- | ------------------------ | ---------------------- | ---------------- |
    // | A1 | IB Token Supply          | 40 ether               | IB WETH          |
    // | A2 | Underlying Total Token   | 40 ether               | WETH             |
    // | A3 | RepayAmount              | 15 ether               | USDC             |
    // | A4 | Liquidation Fee          | 0.15 ether             | 1% of A3         |
    // | A5 | Token Debt Share         | 30 ether               | USDC             |
    // | A6 | Token Debt Value         | 30 ether               | USDC             |
    // | A7 | Debt Pending Interest    | 0.0050765511672 ether  | time past 1 day  |
    // | A8 | Alice Debt Share         | 30 ether               | USDC             |
    // | ------------------------------------------------------------------------- |

    // | Liquidation Strat
    // | ------------------------------------------------------------------------------------------------------ |
    // | #  | Detail                             | Amount      | Note                                           |
    // | -- | ---------------------------------- | ----------- | ---------------------------------------------- |
    // | B1 | IB Collat                          | 30 ether    |                                                |
    // | B2 | RepayAmountWithFee                 | 15.15 ether | A3 + A4                                        |
    // | B3 | RequireUnderlyingToSwap            | 15.15 ether | amountsIn[0] is same A3 because of mock Router |
    // | B4 | Underlying Token Pending Interest  | 0           | Underlying Token is not Debt Token             |
    // | B5 | UnderlyingTotalToken with Interest | 40 ether    | A2 + B4                                        |
    // | B6 | RequireUnderlyingToSwap in (IB)    | 15.15 ether | B3 * A1 / B5                                   |
    // | B7 | To Withdraw IbToken                | 15.15 ether | Min(A1, B6)                                    |
    // | B8 | Underlying Token From Strat        | 15.15 ether | should be same as B2                           |
    // | B9 | Returned IB Token                  | 14.85 ether | if B1 > B7 then B1 - B7 else 0                 |
    // | ------------------------------------------------------------------------------------------------------ |

    // | Summary
    // | ------------------------------------------------------------------------------------
    // | #  | Detail                     | Amount (ether)        | Note
    // | -- | -------------------------- | --------------------- | ------------------------------
    // | C1 | ActualRepaidAmount         | 15                    | B8 - A4 (keep liquidation fee)
    // | C2 | DebtValue with Interest    | 30.0050765511672      | A6 + A7
    // | C3 | RepaidShare                | 14.997462153866591690 | C1 * A5 / C2
    // |    |                            |                       | 15 * 30 / 30.0050765511672
    // | C4 | Debt Share After Liq       | 15.00253784613340831  | A5 - C2, USDC Share
    // | C5 | Debt Value After Liq       | 15.0050765511672      | C3 - C1, USDC
    // | C6 | Alice Debt Share           | 15.00253784613340831  | A8 - C2
    // | C7 | Withdrawn IB Token         | 15.15                 | B7
    // | C8 | Withdrawn Underlying Token | 15.15                 | B8

    liquidationFacet.liquidationCall(
      address(_ibTokenLiquidationStrat),
      ALICE,
      _aliceSubAccountId,
      _debtToken,
      _ibCollatToken,
      _repayAmountInput,
      abi.encode(0)
    );

    // Expectation
    uint256 _expectedIbTokenToWithdraw = 15.15 ether;
    uint256 _expectedUnderlyingWitdrawnAmount = 15.15 ether;
    uint256 _expectedRepaidAmount = 15 ether;

    _assertDebt(ALICE, _aliceSubAccountId, _debtToken, _expectedRepaidAmount, _pendingInterest, _stateBefore);
    _assertIbTokenCollatAndTotalSupply(_aliceSubAccount0, _ibCollatToken, _expectedIbTokenToWithdraw, _stateBefore);
    _assertWithdrawnUnderlying(_underlyingToken, _expectedUnderlyingWitdrawnAmount, _stateBefore);
    _assertTreasuryDebtTokenFee(_debtToken, _liquidationFee, _stateBefore);
  }

  // function testCorrectness_WhenLiquidateIbMoreThanDebt_ShouldLiquidateAllDebtOnThatToken() external {
  //   /**
  //    * todo: simulate if weth has debt, should still correct
  //    * scenario:
  //    *
  //    * 1. 1 usdc/weth, ALICE post 40 ibWeth (value 40 weth) as collateral, borrow 30 usdc
  //    *    - ALICE borrowing power = 40 * 1 * 9000 / 10000 = 36 usd
  //    *
  //    * 2. 1 day passesd, debt accrued, weth price drops to 0.8 usdc/weth, increase shareValue of ibWeth by 2.5%, position become liquidatable
  //    *    - usdc debt has increased to 30.0050765511672 usdc
  //    *    - now 1 ibWeth = 1.025 weth
  //    *    - ALICE borrowing power = 41 * 0.8 * 9000 / 10000 = 29.52 usd
  //    *
  //    * 3. try to liquidate 40 usdc with ibWeth collateral
  //    *    - entire 30.0050765511672 usdc position should be liquidated
  //    *
  //    * 4. should be able to liquidate with 30.0050765511672 usdc repaid and 36.957472337413258535 ibWeth reduced from collateral
  //    *    - remaining collateral = 41 - 36.957472337413258535 = 3.042527662586741465 ibWeth
  //    *      - 30.0050765511672 usdc = 37.506345688959 weth = 36.5915567697160975... ibWeth is liquidated
  //    *      - 30.0050765511672 * 1% = 0.300050765511672 usdc is taken to treasury as liquidation fee
  //    *    - remaining debt value = 0 usdc
  //    *    - remaining debt share = 0 shares
  //    */

  //   adminFacet.setLiquidationParams(10000, 9000); // allow liquidation of entire subAccount

  //   // add ib as collat
  //   vm.startPrank(ALICE);
  //   lendFacet.deposit(address(weth), 40 ether);
  //   collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
  //   collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
  //   vm.stopPrank();

  //   address _debtToken = address(usdc);
  //   address _collatToken = address(ibWeth);
  //   uint256 _repayAmount = 40 ether;

  //   vm.warp(block.timestamp + 1 days);

  //   // increase shareValue of ibWeth by 2.5%
  //   // would need 36.5915567697161341463414634... ibWeth to redeem 37.506345688959 weth to repay debt
  //   vm.prank(BOB);
  //   lendFacet.deposit(address(weth), 1 ether);
  //   vm.prank(moneyMarketDiamond);
  //   ibWeth.onWithdraw(BOB, BOB, 0, 1 ether);

  //   // mm state before
  //   uint256 _totalSupplyIbWethBefore = ibWeth.totalSupply();
  //   uint256 _totalWethInMMBefore = weth.balanceOf(address(moneyMarketDiamond));
  //   uint256 _treasuryFeeBefore = MockERC20(_debtToken).balanceOf(treasury);

  //   // set price to weth from 1 to 0.8 ether USD
  //   // then alice borrowing power = 41 * 0.8 * 9000 / 10000 = 29.52 ether USD
  //   mockOracle.setTokenPrice(address(weth), 8e17);
  //   mockOracle.setTokenPrice(address(usdc), 1e18);

  //   liquidationFacet.liquidationCall(
  //     address(mockLiquidationStrategy),
  //     ALICE,
  //     _subAccountId,
  //     _debtToken,
  //     _collatToken,
  //     _repayAmount,
  //     abi.encode()
  //   );

  //   CacheState memory _stateAfter = CacheState({
  //     collat: viewFacet.getTotalCollat(_collatToken),
  //     subAccountCollat: viewFacet.getOverCollatSubAccountCollatAmount(_aliceSubAccount0, _collatToken),
  //     debtShare: viewFacet.getOverCollatTokenDebtShares(_debtToken),
  //     debtValue: viewFacet.getOverCollatDebtValue(_debtToken),
  //     subAccountDebtShare: 0
  //   });
  //   (_stateAfter.subAccountDebtShare, ) = viewFacet.getOverCollatSubAccountDebt(ALICE, 0, _debtToken);

  //   assertEq(_stateAfter.collat, 3.042527662586741464 ether); // 3.04252766258674146341... repeat 46341
  //   assertEq(_stateAfter.subAccountCollat, 3.042527662586741464 ether); // 3.04252766258674146341... repeat 46341
  //   assertEq(_stateAfter.debtValue, 0);
  //   assertEq(_stateAfter.debtShare, 0);
  //   assertEq(_stateAfter.subAccountDebtShare, 0);

  //   // check mm state after
  //   assertEq(_totalSupplyIbWethBefore - ibWeth.totalSupply(), 36.957472337413258536 ether); // ibWeth repaid + liquidation fee
  //   assertEq(_totalWethInMMBefore - weth.balanceOf(address(moneyMarketDiamond)), 37.88140914584859 ether); // weth repaid + liquidation fee

  //   assertEq(MockERC20(_debtToken).balanceOf(treasury) - _treasuryFeeBefore, 0.300050765511672 ether);
  // }

  // function testRevert_WhenLiquidateButMMDoesNotHaveEnoughUnderlyingForLiquidation() external {
  //   vm.startPrank(ALICE);
  //   lendFacet.deposit(address(weth), 40 ether);
  //   collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
  //   collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
  //   vm.stopPrank();

  //   vm.warp(1 days + 1);

  //   mockOracle.setTokenPrice(address(weth), 1 ether);
  //   mockOracle.setTokenPrice(address(usdc), 1 ether);

  //   vm.startPrank(BOB);
  //   collateralFacet.addCollateral(BOB, 0, address(usdc), 100 ether);
  //   borrowFacet.borrow(0, address(weth), 30 ether);
  //   vm.stopPrank();

  //   vm.prank(BOB);
  //   lendFacet.deposit(address(weth), 1 ether);
  //   vm.prank(moneyMarketDiamond);
  //   ibWeth.onWithdraw(BOB, BOB, 0, 1 ether);

  //   mockOracle.setTokenPrice(address(weth), 8e17);
  //   // todo: check this

  //   // should fail because 11 weth left in mm not enough to liquidate 15 usdc debt
  //   vm.expectRevert("!safeTransfer");
  //   liquidationFacet.liquidationCall(
  //     address(mockLiquidationStrategy),
  //     ALICE,
  //     _subAccountId,
  //     address(usdc),
  //     address(ibWeth),
  //     15 ether,
  //     abi.encode()
  //   );
  // }

  // function testRevert_WhenLiquidateIbWhileSubAccountIsHealthy() external {
  //   // add ib as collat
  //   vm.startPrank(ALICE);
  //   lendFacet.deposit(address(weth), 40 ether);
  //   collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
  //   collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
  //   vm.stopPrank();

  //   // increase shareValue of ibWeth by 2.5%
  //   // wouldn need 18.475609756097... ibWeth to redeem 18.9375 weth to repay debt
  //   vm.prank(BOB);
  //   lendFacet.deposit(address(weth), 4 ether);
  //   vm.prank(moneyMarketDiamond);
  //   ibWeth.onWithdraw(BOB, BOB, 0, 4 ether);
  //   // set price to weth from 1 to 0.8 ether USD
  //   // since ibWeth collat value increase, alice borrowing power = 44 * 0.8 * 9000 / 10000 = 31.68 ether USD
  //   mockOracle.setTokenPrice(address(weth), 8e17);
  //   mockOracle.setTokenPrice(address(usdc), 1e18);
  //   mockOracle.setTokenPrice(address(btc), 10 ether);

  //   vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_Healthy.selector));
  //   liquidationFacet.liquidationCall(
  //     address(mockLiquidationStrategy),
  //     ALICE,
  //     _subAccountId,
  //     address(usdc),
  //     address(ibWeth),
  //     1 ether,
  //     abi.encode()
  //   );
  // }

  // function testRevert_WhenIbLiquidateMoreThanThreshold() external {
  //   vm.startPrank(ALICE);
  //   lendFacet.deposit(address(weth), 40 ether);
  //   collateralFacet.addCollateral(ALICE, 0, address(ibWeth), 40 ether);
  //   collateralFacet.removeCollateral(_subAccountId, address(weth), 40 ether);
  //   vm.stopPrank();

  //   address _debtToken = address(usdc);
  //   address _collatToken = address(ibWeth);
  //   uint256 _repayAmount = 30 ether;

  //   mockOracle.setTokenPrice(address(weth), 8e17);
  //   mockOracle.setTokenPrice(address(usdc), 1e18);

  //   vm.expectRevert(abi.encodeWithSelector(ILiquidationFacet.LiquidationFacet_RepayAmountExceedThreshold.selector));
  //   liquidationFacet.liquidationCall(
  //     address(mockLiquidationStrategy),
  //     ALICE,
  //     _subAccountId,
  //     _debtToken,
  //     _collatToken,
  //     _repayAmount,
  //     abi.encode()
  //   );
  // }

  // function testCorrectness_WhenIbLiquidateWithDebtAndInterestOnIb_ShouldAccrueInterestAndLiquidate() external {
  //   /**
  //    * scenario
  //    *
  //    * 1. ALICE add 1.5 ibWeth as collateral, borrow 1 usdc
  //    *    - borrowing power = 1.5 * 1 * 9000 / 10000 = 1.35
  //    *    - used borrowing power = 1 * 1 * 10000 / 9000 = 1.111..
  //    *
  //    * 2. BOB add 10 usdc as collateral, borrow 0.1 weth
  //    *
  //    * 3. 1 second passed, interest accrue on weth 0.001, usdc 0.01
  //    *    - note that in mm base test had lendingFee set to 0. has to account for if not 0
  //    *
  //    * 4. weth price dropped to 0.1 usdc/weth, ALICE position is liquidatable
  //    *    - ALICE borrowing power = 1.5 * 0.1 * 9000 / 10000 = 0.135
  //    *
  //    * 5. liquidate entire position by dumping 1.5 ibWeth to 0.150075 usdc
  //    *    - ibWeth collateral = 1.5 ibWeth = 1.50075 weth = 0.150075 usdc
  //    *
  //    * 6. state after liquidation
  //    *    - collat = 0
  //    *    - liquidation fee = 1.01 * 0.01 = 0.0101 usdc
  //    *    - remaining debt value = 1.01 - (0.150075 - 0.0101) = 0.870025 usdc
  //    */
  //   address _collatToken = address(ibWeth);
  //   address _debtToken = address(usdc);

  //   MockInterestModel _interestModel = new MockInterestModel(0.01 ether);
  //   adminFacet.setInterestModel(address(weth), address(_interestModel));
  //   adminFacet.setInterestModel(address(usdc), address(_interestModel));

  //   vm.startPrank(ALICE);
  //   lendFacet.deposit(address(weth), 2 ether);
  //   collateralFacet.addCollateral(ALICE, subAccount0, _collatToken, 1.5 ether);
  //   borrowFacet.repay(ALICE, subAccount0, _debtToken, 29 ether);
  //   collateralFacet.removeCollateral(subAccount0, address(weth), 40 ether);
  //   vm.stopPrank();

  //   vm.startPrank(BOB);
  //   collateralFacet.addCollateral(BOB, subAccount0, address(usdc), 10 ether);
  //   borrowFacet.borrow(subAccount0, address(weth), 0.1 ether);
  //   vm.stopPrank();

  //   vm.warp(block.timestamp + 1);

  //   assertEq(viewFacet.getGlobalPendingInterest(address(usdc)), 0.01 ether); // from ALICE
  //   assertEq(viewFacet.getGlobalPendingInterest(address(weth)), 0.001 ether); // from BOB

  //   mockOracle.setTokenPrice(address(weth), 0.1 ether);

  //   liquidationFacet.liquidationCall(
  //     address(mockLiquidationStrategy),
  //     ALICE,
  //     _subAccountId,
  //     _debtToken,
  //     _collatToken,
  //     2 ether,
  //     abi.encode()
  //   );

  //   // ALICE is rekt
  //   assertEq(viewFacet.getOverCollatSubAccountCollatAmount(_aliceSubAccount0, _collatToken), 0);
  //   (, uint256 _debtAmount) = viewFacet.getOverCollatSubAccountDebt(ALICE, subAccount0, _debtToken);
  //   assertEq(_debtAmount, 0.870025 ether);

  //   // check mm state
  //   assertEq(viewFacet.getTotalCollat(_collatToken), 0);
  //   assertEq(viewFacet.getOverCollatDebtValue(_debtToken), 0.870025 ether);
  //   // accrue weth properly
  //   assertEq(viewFacet.getGlobalPendingInterest(address(weth)), 0);
  //   assertEq(viewFacet.getDebtLastAccrueTime(address(weth)), block.timestamp);
  //   assertEq(viewFacet.getTotalToken(address(weth)), 0.50025 ether); // 2.001 - 1.50075
  //   assertEq(viewFacet.getTotalTokenWithPendingInterest(address(weth)), 0.50025 ether); // 2.001 - 1.50075
  // }

  // TODO: case where diamond has no actual token to transfer to strat

  function _cacheState(
    address _subAccount,
    address _ibToken,
    address _underlyingToken,
    address _debtToken
  ) internal view returns (CacheState memory _state) {
    (uint256 _subAccountDebtShare, ) = viewFacet.getOverCollatSubAccountDebt(ALICE, 0, _debtToken);
    _state = CacheState({
      mmUnderlyingBalance: IERC20(_underlyingToken).balanceOf(address(moneyMarketDiamond)),
      ibTokenTotalSupply: IERC20(_ibToken).totalSupply(),
      treasuryDebtTokenBalance: MockERC20(_debtToken).balanceOf(treasury),
      globalDebtValue: viewFacet.getGlobalDebtValue(_debtToken),
      debtValue: viewFacet.getOverCollatDebtValue(_debtToken),
      debtShare: viewFacet.getOverCollatTokenDebtShares(_debtToken),
      subAccountDebtShare: _subAccountDebtShare,
      ibTokenCollat: viewFacet.getTotalCollat(_ibToken),
      subAccountIbTokenCollat: viewFacet.getOverCollatSubAccountCollatAmount(_subAccount, _ibToken)
    });
  }

  function _assertDebt(
    address _account,
    uint256 _subAccountId,
    address _debtToken,
    uint256 _actualRepaidAmount,
    uint256 _pendingInterest,
    CacheState memory _cache
  ) internal {
    (uint256 _subAccountDebtShare, ) = viewFacet.getOverCollatSubAccountDebt(_account, _subAccountId, _debtToken);
    uint256 _debtValueWithInterest = _cache.debtValue + _pendingInterest;
    uint256 _globalValueWithInterest = _cache.globalDebtValue + _pendingInterest;
    uint256 _repaidShare = (_actualRepaidAmount * _cache.debtShare) / (_debtValueWithInterest);

    assertEq(viewFacet.getOverCollatDebtValue(_debtToken), _debtValueWithInterest - _actualRepaidAmount, "debt value");
    assertEq(viewFacet.getOverCollatTokenDebtShares(_debtToken), _cache.debtShare - _repaidShare, "debt share");
    assertEq(_subAccountDebtShare, _cache.subAccountDebtShare - _repaidShare, "sub account debt share");

    // globalDebt should equal to debtValue since there is only 1 position
    assertEq(
      viewFacet.getGlobalDebtValue(_debtToken),
      _globalValueWithInterest - _actualRepaidAmount,
      "global debt value"
    );
  }

  function _assertIbTokenCollatAndTotalSupply(
    address _subAccount,
    address _ibToken,
    uint256 _withdrawnIbToken,
    CacheState memory _cache
  ) internal {
    assertEq(IERC20(_ibToken).totalSupply(), _cache.ibTokenTotalSupply - _withdrawnIbToken, "ibToken totalSupply diff");

    assertEq(viewFacet.getTotalCollat(_ibToken), _cache.ibTokenCollat - _withdrawnIbToken, "collatertal");
    assertEq(
      viewFacet.getOverCollatSubAccountCollatAmount(_subAccount, _ibToken),
      _cache.subAccountIbTokenCollat - _withdrawnIbToken,
      "sub account collatertal"
    );
  }

  function _assertWithdrawnUnderlying(
    address _underlyingToken,
    uint256 _withdrawnAmount,
    CacheState memory _cache
  ) internal {
    assertEq(
      IERC20(_underlyingToken).balanceOf(address(moneyMarketDiamond)),
      _cache.mmUnderlyingBalance - _withdrawnAmount,
      "MM underlying balance should not be affected"
    );
  }

  function _assertTreasuryDebtTokenFee(
    address _debtToken,
    uint256 _liquidationFee,
    CacheState memory _cache
  ) internal {
    assertEq(MockERC20(_debtToken).balanceOf(treasury), _cache.treasuryDebtTokenBalance + _liquidationFee, "treasury");
  }
}
