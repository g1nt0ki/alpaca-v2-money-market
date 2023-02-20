// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import "../BaseScript.sol";

import { InterestBearingToken } from "solidity/contracts/money-market/InterestBearingToken.sol";
import { DebtToken } from "../../contracts/money-market/DebtToken.sol";
import { LibMoneyMarket01 } from "solidity/contracts/money-market/libraries/LibMoneyMarket01.sol";
import { MockAlpacaV2Oracle } from "solidity/tests/mocks/MockAlpacaV2Oracle.sol";

contract SetUpMMForTestScript is BaseScript {
  using stdJson for string;

  function run() public {
    _loadAddresses();

    _startDeployerBroadcast();

    //---- setup tokens ----//
    address wbnb = _setUpMockToken("MOCKBNB", 18);
    address busd = _setUpMockToken("MOCKBUSD", 18);
    address dodo = _setUpMockToken("MOCKDODO", 18);
    address pstake = _setUpMockToken("MOCKPSTAKE", 18);
    address mock6DecimalsToken = _setUpMockToken("MOCK6", 6);

    string memory configJson;
    configJson.serialize("bnb", wbnb);
    configJson.serialize("busd", busd);
    configJson.serialize("dodo", dodo);
    configJson.serialize("pstake", pstake);
    configJson = configJson.serialize("mock6DecimalsToken", mock6DecimalsToken);
    _writeJson(configJson, ".tokens");

    //---- setup mock oracle ----//
    MockAlpacaV2Oracle mockOracle = new MockAlpacaV2Oracle();
    mockOracle.setTokenPrice(wbnb, 300 ether);
    mockOracle.setTokenPrice(busd, 1 ether);
    mockOracle.setTokenPrice(dodo, 0.13 ether);
    mockOracle.setTokenPrice(pstake, 0.12 ether);
    mockOracle.setTokenPrice(mock6DecimalsToken, 666 ether);

    moneyMarket.setOracle(address(mockOracle));

    //---- setup mm configs ----//
    moneyMarket.setMinDebtSize(0.1 ether);
    moneyMarket.setMaxNumOfToken(10, 10, 10);

    moneyMarket.setIbTokenImplementation(address(new InterestBearingToken()));
    moneyMarket.setDebtTokenImplementation(address(new DebtToken()));

    //---- open markets ----//
    // avoid stack too deep
    {
      IAdminFacet.TokenConfigInput memory tokenConfigInput = IAdminFacet.TokenConfigInput({
        token: wbnb,
        tier: LibMoneyMarket01.AssetTier.COLLATERAL,
        collateralFactor: 9000,
        borrowingFactor: 9000,
        maxBorrow: 30 ether,
        maxCollateral: 100 ether
      });
      IAdminFacet.TokenConfigInput memory ibTokenConfigInput = tokenConfigInput;
      address ibBnb = moneyMarket.openMarket(wbnb, tokenConfigInput, ibTokenConfigInput);
      tokenConfigInput.token = busd;
      address ibBusd = moneyMarket.openMarket(busd, tokenConfigInput, ibTokenConfigInput);
      tokenConfigInput.token = mock6DecimalsToken;
      address ibMock6 = moneyMarket.openMarket(mock6DecimalsToken, tokenConfigInput, ibTokenConfigInput);
      tokenConfigInput.token = dodo;
      tokenConfigInput.tier = LibMoneyMarket01.AssetTier.CROSS;
      tokenConfigInput.collateralFactor = 0;
      tokenConfigInput.maxCollateral = 0;
      ibTokenConfigInput.tier = LibMoneyMarket01.AssetTier.UNLISTED;
      ibTokenConfigInput.collateralFactor = 0;
      ibTokenConfigInput.maxCollateral = 0;
      address ibDodo = moneyMarket.openMarket(dodo, tokenConfigInput, ibTokenConfigInput);
      tokenConfigInput.token = pstake;
      tokenConfigInput.tier = LibMoneyMarket01.AssetTier.ISOLATE;
      address ibPstake = moneyMarket.openMarket(pstake, tokenConfigInput, ibTokenConfigInput);

      configJson.serialize("ibBnb", ibBnb);
      configJson.serialize("ibBusd", ibBusd);
      configJson.serialize("ibDodo", ibDodo);
      configJson.serialize("ibPstake", ibPstake);
      configJson = configJson.serialize("ibMock6", ibMock6);
      _writeJson(configJson, ".ibTokens");
    }

    _stopBroadcast();

    //---- setup user positions ----//

    _startUserBroadcast();
    // prepare user's tokens
    MockERC20(wbnb).mint(userAddress, 100 ether);
    MockERC20(busd).mint(userAddress, 100 ether);
    MockERC20(mock6DecimalsToken).mint(userAddress, 100e6);
    MockERC20(dodo).mint(userAddress, 100 ether);
    MockERC20(pstake).mint(userAddress, 100 ether);

    MockERC20(wbnb).approve(address(accountManager), type(uint256).max);
    MockERC20(busd).approve(address(accountManager), type(uint256).max);
    MockERC20(mock6DecimalsToken).approve(address(accountManager), type(uint256).max);
    MockERC20(dodo).approve(address(accountManager), type(uint256).max);
    MockERC20(pstake).approve(address(accountManager), type(uint256).max);

    // seed money market
    accountManager.deposit(dodo, 10 ether);
    accountManager.deposit(pstake, 10 ether);
    accountManager.deposit(mock6DecimalsToken, 10e6);

    // subAccount 0
    accountManager.depositAndAddCollateral(0, wbnb, 0.345 ether);

    accountManager.addCollateralFor(userAddress, 0, wbnb, 97.9 ether);
    accountManager.addCollateralFor(userAddress, 0, busd, 10 ether);

    accountManager.borrow(0, dodo, 3.14159 ether);
    accountManager.borrow(0, mock6DecimalsToken, 12e5);

    // subAccount 1
    accountManager.addCollateralFor(userAddress, 1, mock6DecimalsToken, 10e6);

    accountManager.borrow(1, pstake, 2.34 ether);

    _stopBroadcast();
  }
}
