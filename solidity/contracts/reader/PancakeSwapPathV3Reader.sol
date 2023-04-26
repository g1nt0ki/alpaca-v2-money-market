// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { LibPath } from "./LibPath.sol";
import { IPancakeV3Pool } from "../money-market/interfaces/IPancakeV3Pool.sol";
import { IPancakeSwapPathV3Reader } from "./IPancakeSwapPathV3Reader.sol";

contract PancakeSwapPathV3Reader is IPancakeSwapPathV3Reader, Ownable {
  using LibPath for bytes;

  address internal constant PANCAKE_V3_POOL_DEPLOYER = 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9;
  bytes32 internal constant POOL_INIT_CODE_HASH = 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2;

  mapping(address => mapping(address => bytes)) public override paths;

  error PancakeSwapPathV3Reader_NoLiquidity(address tokenA, address tokenB, uint24 fee);

  event LogSetPath(address _token0, address _token1, bytes _path);

  function setPaths(bytes[] calldata _paths) external onlyOwner {
    uint256 _len = _paths.length;
    for (uint256 _i; _i < _len; ) {
      bytes memory _path = _paths[_i];

      while (true) {
        bool hasMultiplePools = LibPath.hasMultiplePools(_path);

        // get first hop (token0, fee, token1)
        bytes memory _hop = _path.getFirstPool();
        // extract the token from encoded hop
        (address _token0, address _token1, uint24 _fee) = _hop.decodeFirstPool();

        // compute pool address from token0, token1 and fee
        address _pool = _computeAddressV3(_token0, _token1, _fee);

        // revert EVM error if pool is not existing (cannot call liquidity)
        if (IPancakeV3Pool(_pool).liquidity() == 0) {
          // revert no liquidity if there's no liquidity
          revert PancakeSwapPathV3Reader_NoLiquidity(_token0, _token1, _fee);
        }

        // if true, go to the next hop
        if (hasMultiplePools) {
          _path = _path.skipToken();
        } else {
          // if it's last hop
          // Get source token address from first hop
          (address _source, , ) = _paths[_i].decodeFirstPool();
          // Get destination token from last hop
          (, address _destination, ) = _path.decodeFirstPool();
          // Assign to global paths
          paths[_source][_destination] = _paths[_i];
          emit LogSetPath(_source, _destination, _paths[_i]);
          break;
        }
      }

      unchecked {
        ++_i;
      }
    }
  }

  function _computeAddressV3(
    address _tokenA,
    address _tokenB,
    uint24 _fee
  ) internal pure returns (address pool) {
    if (_tokenA > _tokenB) (_tokenA, _tokenB) = (_tokenB, _tokenA);
    pool = address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              hex"ff",
              PANCAKE_V3_POOL_DEPLOYER,
              keccak256(abi.encode(_tokenA, _tokenB, _fee)),
              POOL_INIT_CODE_HASH
            )
          )
        )
      )
    );
  }
}
