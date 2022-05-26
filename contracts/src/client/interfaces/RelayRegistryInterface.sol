// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../../utils/RelayTypes.sol';

/**
 * @notice config of the registry
 * @dev only used in params and return values
 * @member paymentPremiumPPB payment premium rate oracles receive on top of
 * being reimbursed for gas, measured in parts per billion
 * @member flatFeeMicroLink flat fee paid to oracles for performing relays,
 * priced in MicroLink; can be used in conjunction with or independently of
 * paymentPremiumPPB
 * @member blockCountPerTurn number of blocks each oracle has during their turn to
 * perform relay before it will be the next relayer's turn to submit
 * @member checkGasLimit gas limit when checking a relay
 * @member stalenessSeconds number of seconds that is allowed for feed data to
 * be stale before switching to the fallback pricing
 * @member gasCeilingMultiplier multiplier to apply to the fast gas feed price
 * when calculating the payment ceiling for relayers
 * @member minRelaySpend minimum LINK that an relay must spend before cancelling
 * @member maxPerformGas max executeGas allowed for a relay on this registry
 * @member fallbackGasPrice gas price used if the gas price feed is stale
 * @member fallbackLinkPrice LINK price used if the LINK price feed is stale
 * @member registrar address of the registrar contract
 */
struct Config {
    uint32 paymentPremiumPPB;
    uint32 flatFeeMicroLink; // min 0.000001 LINK, max 4294 LINK
    uint24 blockCountPerTurn;
    uint32 checkGasLimit;
    uint24 stalenessSeconds;
    uint16 gasCeilingMultiplier;
    uint96 minRelaySpend;
    uint32 maxPerformGas;
    uint256 fallbackGasPrice;
    uint256 fallbackLinkPrice;
    address registrar;
}

/**
 * @notice config of the registry
 * @dev only used in params and return values
 * @member nonce used for ID generation
 * @ownerLinkBalance withdrawable balance of LINK by contract owner
 * @numRelays total number of relays on the registry
 */
struct State {
    uint32 nonce;
    uint96 ownerLinkBalance;
    uint256 expectedLinkBalance;
    uint256 numRelays;
}

interface RelayRegistryInterfaceBase {
    function registerRelay(
        address target,
        uint32 gasLimit,
        address client,
        bytes calldata checkData
    ) external returns (uint256 id);

    function performRelay(
        uint256 id,
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata performData
    ) external returns (bool success);

    function cancelRelay(uint256 id) external;

    function addFunds(uint256 id, uint96 amount) external;

    function setRelayGasLimit(uint256 id, uint32 gasLimit) external;

    function getRelay(uint256 id)
        external
        view
        returns (
            address target,
            uint32 executeGas,
            bytes memory checkData,
            uint96 balance,
            address lastRelayer,
            address client,
            uint64 maxValidBlocknumber,
            uint96 amountSpent
        );

    function getActiveRelayIDs(uint256 startIndex, uint256 maxCount)
        external
        view
        returns (uint256[] memory);

    function getRelayerInfo(address query)
        external
        view
        returns (
            address payee,
            bool active,
            uint96 balance
        );

    function getState()
        external
        view
        returns (
            State memory,
            Config memory,
            address[] memory
        );
}

/**
 * @dev The view methods are not actually marked as view in the implementation
 * but we want them to be easily queried off-chain. Solidity will not compile
 * if we actually inherit from this interface, so we document it here.
 */
interface RelayRegistryInterface is RelayRegistryInterfaceBase {
    function checkRelay(
        uint256 relayId,
        address from,
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata signature
    )
        external
        view
        returns (
            bytes memory performData,
            uint256 maxLinkPayment,
            uint256 gasLimit,
            int256 gasWei,
            int256 linkEth
        );
}

interface RelayRegistryExecutableInterface is RelayRegistryInterfaceBase {
    function checkRelay(
        uint256 relayId,
        address from,
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata signature
    )
        external
        returns (
            bytes memory performData,
            uint256 maxLinkPayment,
            uint256 gasLimit,
            uint256 adjustedGasWei,
            uint256 linkEth
        );
}
