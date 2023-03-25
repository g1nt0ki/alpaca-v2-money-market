pragma solidity 0.8.19;

import "../../../BaseScript.sol";

import { InterestBearingToken } from "solidity/contracts/money-market/InterestBearingToken.sol";

contract DeployInterestBearingTokenScript is BaseScript {
  using stdJson for string;

  function run() public {
    _loadAddresses();

    /*
  ░██╗░░░░░░░██╗░█████╗░██████╗░███╗░░██╗██╗███╗░░██╗░██████╗░
  ░██║░░██╗░░██║██╔══██╗██╔══██╗████╗░██║██║████╗░██║██╔════╝░
  ░╚██╗████╗██╔╝███████║██████╔╝██╔██╗██║██║██╔██╗██║██║░░██╗░
  ░░████╔═████║░██╔══██║██╔══██╗██║╚████║██║██║╚████║██║░░╚██╗
  ░░╚██╔╝░╚██╔╝░██║░░██║██║░░██║██║░╚███║██║██║░╚███║╚██████╔╝
  ░░░╚═╝░░░╚═╝░░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚══╝╚═╝╚═╝░░╚══╝░╚═════╝░
  Check all variables below before execute the deployment script
    */

    _startDeployerBroadcast();
    // deploy implementation
    address interestBearingTokenImplementation = address(new InterestBearingToken());
    _stopBroadcast();

    _writeJson(vm.toString(interestBearingTokenImplementation), ".moneyMarket.interestBearingToken");
  }
}
