// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { BaseTest, console } from "../base/BaseTest.sol";

// core
import { MoneyMarketDiamond } from "../../contracts/money-market/MoneyMarketDiamond.sol";
import { InterestBearingToken } from "../../contracts/money-market/InterestBearingToken.sol";

// facets
import { DiamondCutFacet, IDiamondCut } from "../../contracts/money-market/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../../contracts/money-market/facets/DiamondLoupeFacet.sol";
import { LendFacet, ILendFacet } from "../../contracts/money-market/facets/LendFacet.sol";
import { CollateralFacet, ICollateralFacet } from "../../contracts/money-market/facets/CollateralFacet.sol";
import { BorrowFacet, IBorrowFacet } from "../../contracts/money-market/facets/BorrowFacet.sol";
import { NonCollatBorrowFacet, INonCollatBorrowFacet } from "../../contracts/money-market/facets/NonCollatBorrowFacet.sol";
import { AdminFacet, IAdminFacet } from "../../contracts/money-market/facets/AdminFacet.sol";
import { LiquidationFacet, ILiquidationFacet } from "../../contracts/money-market/facets/LiquidationFacet.sol";

// initializers
import { DiamondInit } from "../../contracts/money-market/initializers/DiamondInit.sol";
import { MoneyMarketInit } from "../../contracts/money-market/initializers/MoneyMarketInit.sol";

// interfaces
import { ICollateralFacet } from "../../contracts/money-market/facets/CollateralFacet.sol";
import { IViewFacet } from "../../contracts/money-market/facets/ViewFacet.sol";
import { ILendFacet } from "../../contracts/money-market/facets/LendFacet.sol";
import { IAdminFacet } from "../../contracts/money-market/facets/AdminFacet.sol";
import { IBorrowFacet } from "../../contracts/money-market/facets/BorrowFacet.sol";
import { INonCollatBorrowFacet } from "../../contracts/money-market/facets/NonCollatBorrowFacet.sol";
import { ILiquidationFacet } from "../../contracts/money-market/facets/LiquidationFacet.sol";
import { IOwnershipFacet } from "../../contracts/money-market/facets/OwnershipFacet.sol";

// mocks
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockChainLinkPriceOracle } from "../mocks/MockChainLinkPriceOracle.sol";
import { MockAlpacaV2Oracle } from "../mocks/MockAlpacaV2Oracle.sol";

// libs
import { LibMoneyMarket01 } from "../../contracts/money-market/libraries/LibMoneyMarket01.sol";

// helper
import { MMDiamondDeployer } from "../helper/MMDiamondDeployer.sol";

abstract contract MoneyMarket_BaseTest is BaseTest {
  address internal moneyMarketDiamond;

  IViewFacet internal viewFacet;
  IAdminFacet internal adminFacet;
  ILendFacet internal lendFacet;
  ICollateralFacet internal collateralFacet;
  IBorrowFacet internal borrowFacet;
  INonCollatBorrowFacet internal nonCollatBorrowFacet;
  ILiquidationFacet internal liquidationFacet;
  IOwnershipFacet internal ownershipFacet;

  MockAlpacaV2Oracle internal mockOracle;

  function setUp() public virtual {
    moneyMarketDiamond = MMDiamondDeployer.deployPoolDiamond(address(nativeToken), address(nativeRelayer));

    viewFacet = IViewFacet(moneyMarketDiamond);
    lendFacet = ILendFacet(moneyMarketDiamond);
    collateralFacet = ICollateralFacet(moneyMarketDiamond);
    adminFacet = IAdminFacet(moneyMarketDiamond);
    borrowFacet = IBorrowFacet(moneyMarketDiamond);
    nonCollatBorrowFacet = INonCollatBorrowFacet(moneyMarketDiamond);
    liquidationFacet = ILiquidationFacet(moneyMarketDiamond);
    ownershipFacet = IOwnershipFacet(moneyMarketDiamond);

    // set ib token implementation
    // warning: this one should set before open market
    adminFacet.setIbTokenImplementation(address(new InterestBearingToken()));

    address _ibWeth = adminFacet.openMarket(address(weth));
    address _ibUsdc = adminFacet.openMarket(address(usdc));
    address _ibBtc = adminFacet.openMarket(address(btc));
    address _ibNativeToken = adminFacet.openMarket(address(nativeToken));

    ibWeth = InterestBearingToken(_ibWeth);
    ibUsdc = InterestBearingToken(_ibUsdc);
    ibBtc = InterestBearingToken(_ibBtc);
    ibWNative = InterestBearingToken(_ibNativeToken);

    vm.startPrank(ALICE);
    weth.approve(moneyMarketDiamond, type(uint256).max);
    btc.approve(moneyMarketDiamond, type(uint256).max);
    usdc.approve(moneyMarketDiamond, type(uint256).max);
    opm.approve(moneyMarketDiamond, type(uint256).max);
    isolateToken.approve(moneyMarketDiamond, type(uint256).max);
    ibWeth.approve(moneyMarketDiamond, type(uint256).max);
    vm.stopPrank();

    vm.startPrank(BOB);
    weth.approve(moneyMarketDiamond, type(uint256).max);
    btc.approve(moneyMarketDiamond, type(uint256).max);
    usdc.approve(moneyMarketDiamond, type(uint256).max);
    isolateToken.approve(moneyMarketDiamond, type(uint256).max);
    vm.stopPrank();

    IAdminFacet.TokenConfigInput[] memory _inputs = new IAdminFacet.TokenConfigInput[](6);

    _inputs[0] = IAdminFacet.TokenConfigInput({
      token: address(weth),
      tier: LibMoneyMarket01.AssetTier.COLLATERAL,
      collateralFactor: 9000,
      borrowingFactor: 9000,
      maxBorrow: 30e18,
      maxCollateral: 100e18
    });

    _inputs[1] = IAdminFacet.TokenConfigInput({
      token: address(usdc),
      tier: LibMoneyMarket01.AssetTier.COLLATERAL,
      collateralFactor: 9000,
      borrowingFactor: 9000,
      maxBorrow: 1e24,
      maxCollateral: 10e24
    });

    _inputs[2] = IAdminFacet.TokenConfigInput({
      token: address(ibWeth),
      tier: LibMoneyMarket01.AssetTier.COLLATERAL,
      collateralFactor: 9000,
      borrowingFactor: 9000,
      maxBorrow: 30e18,
      maxCollateral: 100e18
    });

    _inputs[3] = IAdminFacet.TokenConfigInput({
      token: address(btc),
      tier: LibMoneyMarket01.AssetTier.COLLATERAL,
      collateralFactor: 9000,
      borrowingFactor: 9000,
      maxBorrow: 30e18,
      maxCollateral: 100e18
    });

    _inputs[4] = IAdminFacet.TokenConfigInput({
      token: address(nativeToken),
      tier: LibMoneyMarket01.AssetTier.COLLATERAL,
      collateralFactor: 9000,
      borrowingFactor: 9000,
      maxBorrow: 30e18,
      maxCollateral: 100e18
    });

    _inputs[5] = IAdminFacet.TokenConfigInput({
      token: address(ibUsdc),
      tier: LibMoneyMarket01.AssetTier.COLLATERAL,
      collateralFactor: 9000,
      borrowingFactor: 9000,
      maxBorrow: 30e18,
      maxCollateral: 100e18
    });

    adminFacet.setTokenConfigs(_inputs);

    IAdminFacet.TokenBorrowLimitInput[] memory _tokenBorrowLimitInputs = new IAdminFacet.TokenBorrowLimitInput[](3);
    _tokenBorrowLimitInputs[0] = IAdminFacet.TokenBorrowLimitInput({ token: address(weth), maxTokenBorrow: 30e18 });
    _tokenBorrowLimitInputs[1] = IAdminFacet.TokenBorrowLimitInput({ token: address(usdc), maxTokenBorrow: 30e18 });
    _tokenBorrowLimitInputs[2] = IAdminFacet.TokenBorrowLimitInput({ token: address(btc), maxTokenBorrow: 30e18 });

    IAdminFacet.ProtocolConfigInput[] memory _protocolConfigInputs = new IAdminFacet.ProtocolConfigInput[](2);
    _protocolConfigInputs[0] = IAdminFacet.ProtocolConfigInput({
      account: ALICE,
      tokenBorrowLimit: _tokenBorrowLimitInputs,
      borrowLimitUSDValue: 1e30
    });
    _protocolConfigInputs[1] = IAdminFacet.ProtocolConfigInput({
      account: BOB,
      tokenBorrowLimit: _tokenBorrowLimitInputs,
      borrowLimitUSDValue: 1e30
    });

    adminFacet.setProtocolConfigs(_protocolConfigInputs);

    // open isolate token market
    address _ibIsolateToken = adminFacet.openMarket(address(isolateToken));
    ibIsolateToken = InterestBearingToken(_ibIsolateToken);

    //set oracle

    mockOracle = new MockAlpacaV2Oracle();
    mockOracle.setTokenPrice(address(weth), 1e18);
    mockOracle.setTokenPrice(address(usdc), 1e18);
    mockOracle.setTokenPrice(address(isolateToken), 1e18);
    mockOracle.setTokenPrice(address(btc), 10e18);

    adminFacet.setOracle(address(mockOracle));

    // set repurchases ok
    address[] memory _repurchasers = new address[](1);
    _repurchasers[0] = BOB;
    adminFacet.setRepurchasersOk(_repurchasers, true);

    adminFacet.setTreasury(address(this));

    // adminFacet.setFees(_newLendingFeeBps, _newRepurchaseRewardBps, _newRepurchaseFeeBps, _newLiquidationFeeBps);
    adminFacet.setFees(0, 100, 100, 100);

    adminFacet.setMaxLiquidateBps(5000); // 50%
  }
}
