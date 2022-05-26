// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/Context.sol';

// TODO: - revert transaction if checks not correct/invalid info/ transaction already completed

contract RelayBase {
    error OnlySimulatedBackend();
    error OnlyCallableByRegistry();

    /**
     * @notice method that allows it to be simulated via eth_call by checking that
     * the sender is the zero address.
     */
    function preventExecution() internal view virtual {
        if (tx.origin != address(0)) {
            revert OnlySimulatedBackend();
        }
    }

    function checkOnlyRegistry(address registry) internal view virtual {
        if (msg.sender != registry) {
            revert OnlyCallableByRegistry();
        }
    }

    /**
     * @notice modifier that allows it to be simulated via eth_call by checking
     * that the sender is the zero address.
     */
    modifier cannotExecute() {
        preventExecution();
        _;
    }

    modifier onlyRegistry(address registry) {
        checkOnlyRegistry(registry);
        _;
    }

    function _msgSenderBase() internal view returns (address sender) {
        if (msg.data.length >= 20 && msg.sender == address(this)) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    function _msgDataBase() internal view returns (bytes calldata data) {
        if (msg.data.length >= 20 && msg.sender == address(this)) {
            return msg.data[0:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }
}
