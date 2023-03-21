// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

import { LibDiamond } from "./libraries/LibDiamond.sol";
import { LibLYF01 } from "./libraries/LibLYF01.sol";
import { ILYFDiamondCut } from "./interfaces/ILYFDiamondCut.sol";
import { ILYFDiamondLoupe } from "./interfaces/ILYFDiamondLoupe.sol";
import { ILYFDiamondCut } from "./interfaces/ILYFDiamondCut.sol";
import { IERC173 } from "./interfaces/IERC173.sol";
import { IERC165 } from "./interfaces/IERC165.sol";
import { ILYFAdminFacet } from "./interfaces/ILYFAdminFacet.sol";
import { IMoneyMarket } from "./interfaces/IMoneyMarket.sol";

contract LYFDiamond {
  constructor(address _LYFDiamondCutFacet, address _moneyMarket) {
    LibDiamond.setContractOwner(msg.sender);

    ILYFDiamondCut.FacetCut[] memory cut = new ILYFDiamondCut.FacetCut[](1);
    bytes4[] memory functionSelectors = new bytes4[](1);
    functionSelectors[0] = ILYFDiamondCut.diamondCut.selector;
    cut[0] = ILYFDiamondCut.FacetCut({
      facetAddress: _LYFDiamondCutFacet,
      action: ILYFDiamondCut.FacetCutAction.Add,
      functionSelectors: functionSelectors
    });
    LibDiamond.diamondCut(cut, address(0), "");

    // adding ERC165 data
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    ds.supportedInterfaces[type(IERC165).interfaceId] = true;
    ds.supportedInterfaces[type(ILYFDiamondCut).interfaceId] = true;
    ds.supportedInterfaces[type(ILYFDiamondLoupe).interfaceId] = true;
    ds.supportedInterfaces[type(IERC173).interfaceId] = true;

    // todo: add lyf interfaces

    // sanity check for MM
    IMoneyMarket(_moneyMarket).getIbTokenFromToken(address(0));

    LibLYF01.LYFDiamondStorage storage lyfDs = LibLYF01.lyfDiamondStorage();

    lyfDs.moneyMarket = IMoneyMarket(_moneyMarket);
  }

  // Find facet for function that is called and execute the
  // function if a facet is found and return any value.
  fallback() external payable {
    LibDiamond.DiamondStorage storage ds;
    bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
    // get diamond storage
    assembly {
      ds.slot := position
    }
    // get facet from function selector
    address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
    require(facet != address(0), "Diamond: Function does not exist");
    // Execute external function from facet using delegatecall and return any value.
    assembly {
      // copy function selector and any arguments
      calldatacopy(0, 0, calldatasize())
      // execute function call using the facet
      let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
      // get any return value
      returndatacopy(0, 0, returndatasize())
      // return any return value or error back to the caller
      switch result
      case 0 {
        revert(0, returndatasize())
      }
      default {
        return(0, returndatasize())
      }
    }
  }

  receive() external payable {}
}
