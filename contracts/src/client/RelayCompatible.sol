// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './RelayBase.sol';
import './interfaces/RelayCompatibleInterface.sol';

abstract contract RelayCompatible is RelayBase, RelayCompatibleInterface {}
