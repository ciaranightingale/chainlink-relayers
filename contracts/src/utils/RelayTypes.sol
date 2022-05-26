// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library RelayTypes {
    struct RelayRequest {
        address from;
        address to;
        uint256 value; //mgs.value ether sent with contract call (0)
        uint256 gas; //200 gwei
        uint256 nonce; //(0)
        bytes data; //NOTE: abi encoded selector and params (specific func called)
    }
}
