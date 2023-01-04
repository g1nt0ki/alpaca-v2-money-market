// SPDX-License-Identifier: BUSL
pragma solidity 0.8.17;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { ILYFOwnershipFacet } from "../interfaces/ILYFOwnershipFacet.sol";

contract LYFOwnershipFacet is ILYFOwnershipFacet {
  /**
   * @dev Transfer ownership by set new owner as pending owner
   */
  function transferOwnership(address _newOwner) external override {
    LibDiamond.enforceIsContractOwner();

    LibDiamond.setPendingOwner(_newOwner);

    emit OwnershipTransferStarted(LibDiamond.contractOwner(), _newOwner);
  }

  /**
   * @dev Accept pending owner to be new owner
   */
  function acceptOwnership() external {
    address _pendingOwner = LibDiamond.pendingOwner();
    if (msg.sender != _pendingOwner) revert LYFOwnershipFacet_CallerIsNotPendingOwner();

    address _previousOwner = LibDiamond.contractOwner();
    LibDiamond.setContractOwner(_pendingOwner);
    LibDiamond.setPendingOwner(address(0));

    emit OwnershipTransferred(_previousOwner, LibDiamond.contractOwner());
  }

  /**
   * @dev Returns the address of the current owner.
   */
  function owner() external view override returns (address owner_) {
    owner_ = LibDiamond.contractOwner();
  }

  /**
   * @dev Returns the address of the pending owner.
   */
  function pendingOwner() external view returns (address pendingOwner_) {
    pendingOwner_ = LibDiamond.pendingOwner();
  }
}
