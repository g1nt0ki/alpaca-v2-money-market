// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { MoneyMarket_BaseTest, console } from "../MoneyMarket_BaseTest.t.sol";

// contracts
import { InterestBearingToken } from "../../../contracts/money-market/InterestBearingToken.sol";

// interfaces
import { IAdminFacet, LibMoneyMarket01 } from "../../../contracts/money-market/facets/AdminFacet.sol";

contract InterestBearingToken_ERC4626Test is MoneyMarket_BaseTest {
  InterestBearingToken internal ibToken;

  function setUp() public override {
    super.setUp();

    ibToken = new InterestBearingToken();
    ibToken.initialize(address(weth), moneyMarketDiamond);
  }

  function testCorrectness_WhenCallImplementedGetterMethods_ShouldWork() external {
    // static stuff
    assertEq(ibToken.asset(), address(weth));
    assertEq(ibToken.maxDeposit(ALICE), type(uint256).max);
    assertEq(ibToken.name(), string.concat("Interest Bearing ", weth.symbol()));
    assertEq(ibToken.symbol(), string.concat("ib", weth.symbol()));
    assertEq(ibToken.decimals(), weth.decimals());

    // empty state
    assertEq(ibToken.totalAssets(), 0);
    assertEq(ibToken.convertToAssets(1 ether), 1 ether);
    assertEq(ibToken.convertToShares(1 ether), 1 ether);
    assertEq(ibToken.previewDeposit(1 ether), ibToken.convertToShares(1 ether));
    assertEq(ibToken.previewRedeem(1 ether), ibToken.convertToAssets(1 ether));

    // simulate deposit by deposit to diamond to increase reserves and call onDeposit to mint ibToken
    // need to do like this because ibWeth deployed by diamond is not the same as ibToken deployed in this test
    // 1 ibToken = 2 weth
    vm.prank(ALICE);
    lendFacet.deposit(address(weth), 2 ether);
    vm.prank(moneyMarketDiamond);
    ibToken.onDeposit(ALICE, 0, 1 ether);

    // state after deposit
    assertEq(ibToken.totalAssets(), 2 ether);
    assertEq(ibToken.convertToAssets(1 ether), 2 ether);
    assertEq(ibToken.convertToShares(1 ether), 0.5 ether);
    assertEq(ibToken.previewDeposit(1 ether), ibToken.convertToShares(1 ether));
    assertEq(ibToken.previewRedeem(1 ether), ibToken.convertToAssets(1 ether));
  }
}
