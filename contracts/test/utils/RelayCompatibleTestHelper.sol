// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../../src/client/RelayCompatible.sol';
import '../../src/utils/RelayTypes.sol';

contract RelayCompatibleTestHelper is RelayCompatible {
    function checkRelay(
        RelayTypes.RelayRequest memory,
        bytes calldata,
        bytes calldata
    ) external override returns (bool, bytes memory) {}

    function performRelay(RelayTypes.RelayRequest memory, bytes calldata) external override {}

    function helperCannotExecute() public view cannotExecute {}

    function msgSenderBase() public view returns (address) {
        return _msgSenderBase();
    }

    function msgDataBase() public view returns (bytes calldata) {
        return _msgDataBase();
    }
}
